/*
 * Copyright (C) bigplum@gmail.com
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

static ngx_int_t
ngx_http_limit_traffic_rate_filter_handler(ngx_http_request_t *r);
static ngx_int_t
ngx_http_limit_traffic_rate_filter_init(ngx_conf_t *cf);
static ngx_int_t
    ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r, ngx_chain_t *in);
static void* ngx_http_limit_traffic_rate_filter_create_loc_conf(ngx_conf_t *cf);

static char* ngx_http_limit_traffic_rate_filter_merge_loc_conf(ngx_conf_t *cf,
    void *parent, void *child);
static ngx_int_t
ngx_http_limit_traffic_rate_filter_init_zone(ngx_shm_zone_t *shm_zone, void *data);
static void
ngx_http_limit_traffic_rate_filter_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);
static void
ngx_http_limit_traffic_rate_filter_cleanup(void *data);
static char *
ngx_http_limit_traffic_rate_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *
ngx_http_limit_traffic_rate(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);

typedef struct {
    ngx_queue_t rq;
    ngx_http_request_t *r;
    off_t sent;
}ngx_http_limit_traffic_rate_filter_request_queue_t;

typedef struct {
    ngx_shm_zone_t     *shm_zone;
    ngx_rbtree_node_t  *node;
    size_t              limit;
    size_t              limit_rate_after;
    ngx_http_limit_traffic_rate_filter_request_queue_t  *req;
} ngx_http_limit_traffic_rate_filter_cleanup_t;

typedef struct {
    u_char              color;
    u_short              len;
    u_short             conn;
    time_t              start_sec;
    off_t               sent_done;
    ngx_queue_t         idle;       /* in sh->idle while conn == 0 */
    time_t              expire;     /* idle node is not needed after it */
    ngx_queue_t     rq_top;
    u_char              data[1];
} ngx_http_limit_traffic_rate_filter_node_t;

typedef struct {
    ngx_rbtree_t        rbtree;
    ngx_rbtree_node_t   sentinel;
    ngx_queue_t         idle;
} ngx_http_limit_traffic_rate_filter_shctx_t;

typedef struct {
    ngx_rbtree_t       *rbtree;
    ngx_int_t           index;
    ngx_str_t           var;
    ngx_http_limit_traffic_rate_filter_shctx_t  *sh;
} ngx_http_limit_traffic_rate_filter_ctx_t;

typedef struct {
    size_t  limit_traffic_rate;
    ngx_shm_zone_t     *shm_zone;
} ngx_http_limit_traffic_rate_filter_conf_t;

typedef struct {
    size_t  limit_rate;     /* rate set by limit_rate, X-Accel-Limit-Rate... */
    size_t  limit_rate_after;
} ngx_http_limit_traffic_rate_filter_req_ctx_t;


static ngx_command_t  ngx_http_limit_traffic_rate_filter_commands[] = {

    { ngx_string("limit_traffic_rate_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE3,
      ngx_http_limit_traffic_rate_zone,
      0,
      0,
      NULL },

    { ngx_string("limit_traffic_rate"),
        NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE2,
        ngx_http_limit_traffic_rate,
        NGX_HTTP_LOC_CONF_OFFSET,
        0,
        NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_limit_traffic_rate_filter_module_ctx = {
    NULL,                          /* preconfiguration */
    ngx_http_limit_traffic_rate_filter_init,                          /* postconfiguration */

    NULL,                          /* create main configuration */
    NULL,                          /* init main configuration */

    NULL,                          /* create server configuration */
    NULL,                          /* merge server configuration */

    ngx_http_limit_traffic_rate_filter_create_loc_conf,  /* create location configuration */
    ngx_http_limit_traffic_rate_filter_merge_loc_conf /* merge location configuration */
};


ngx_module_t  ngx_http_limit_traffic_rate_filter_module = {
    NGX_MODULE_V1,
    &ngx_http_limit_traffic_rate_filter_module_ctx, /* module context */
    ngx_http_limit_traffic_rate_filter_commands,   /* module directives */
    NGX_HTTP_MODULE,               /* module type */
    NULL,                          /* init master */
    NULL,                          /* init module */
    NULL,                          /* init process */
    NULL,                          /* init thread */
    NULL,                          /* exit thread */
    NULL,                          /* exit process */
    NULL,                          /* exit master */
    NGX_MODULE_V1_PADDING
};

static ngx_http_output_body_filter_pt    ngx_http_next_body_filter;


/*
 * free idle nodes (conn == 0) that have expired, or, if "force" is set
 * after an allocation failure, the least recently used ones
 */

static void
ngx_http_limit_traffic_rate_filter_expire(
    ngx_http_limit_traffic_rate_filter_ctx_t *ctx, ngx_slab_pool_t *shpool,
    ngx_uint_t force)
{
    time_t                                      now;
    ngx_uint_t                                  n;
    ngx_queue_t                                *q;
    ngx_rbtree_node_t                          *node;
    ngx_http_limit_traffic_rate_filter_node_t  *lir;

    now = ngx_time();

    q = ngx_queue_last(&ctx->sh->idle);

    /* the queue is not sorted by expire, so look at a few nodes */

    for (n = 0; n < 3 && q != ngx_queue_sentinel(&ctx->sh->idle); n++) {

        lir = ngx_queue_data(q, ngx_http_limit_traffic_rate_filter_node_t, idle);

        q = ngx_queue_prev(q);

        if (!force && lir->expire > now) {
            continue;
        }

        ngx_queue_remove(&lir->idle);

        node = (ngx_rbtree_node_t *)
                   ((u_char *) lir - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(ctx->rbtree, node);

        ngx_slab_free_locked(shpool, node);
    }
}


static void *
ngx_http_limit_traffic_rate_filter_alloc(
    ngx_http_limit_traffic_rate_filter_ctx_t *ctx, ngx_slab_pool_t *shpool,
    size_t size)
{
    void  *p;

    p = ngx_slab_alloc_locked(shpool, size);

    /* a whole page may be needed, so free idle nodes until it succeeds */

    while (p == NULL && !ngx_queue_empty(&ctx->sh->idle)) {
        ngx_http_limit_traffic_rate_filter_expire(ctx, shpool, 1);
        p = ngx_slab_alloc_locked(shpool, size);
    }

    if (p == NULL) {
        ngx_log_error(NGX_LOG_ALERT, ngx_cycle->log, 0,
                      "could not allocate memory%s", shpool->log_ctx);
    }

    return p;
}


/*
 * a request is registered in a zone by the preaccess handler with a pool
 * cleanup, which unlike the module ctx is kept on internal redirects
 */

static ngx_http_limit_traffic_rate_filter_cleanup_t *
ngx_http_limit_traffic_rate_filter_registered(ngx_http_request_t *r,
    ngx_shm_zone_t *shm_zone)
{
    ngx_pool_cleanup_t                            *cln;
    ngx_http_limit_traffic_rate_filter_cleanup_t  *lircln;

    for (cln = r->pool->cleanup; cln; cln = cln->next) {

        if (cln->handler != ngx_http_limit_traffic_rate_filter_cleanup) {
            continue;
        }

        lircln = cln->data;

        if (lircln->shm_zone == shm_zone) {
            return lircln;
        }
    }

    return NULL;
}



static ngx_int_t
ngx_http_limit_traffic_rate_filter_handler(ngx_http_request_t *r)
{
    size_t                          len, n;
    uint32_t                        hash;
    ngx_int_t                       rc;
    ngx_slab_pool_t                *shpool;
    ngx_rbtree_node_t              *node, *sentinel;
    ngx_queue_t                    *q;
    ngx_pool_cleanup_t             *cln;
    ngx_http_variable_value_t      *vv;
    ngx_http_limit_traffic_rate_filter_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_filter_node_t     *lir;
    ngx_http_limit_traffic_rate_filter_conf_t     *lircf;
    ngx_http_limit_traffic_rate_filter_cleanup_t  *lircln;

    lircf = ngx_http_get_module_loc_conf(r, ngx_http_limit_traffic_rate_filter_module);

    if (lircf->shm_zone == NULL) {
        return NGX_DECLINED;
    }

    if (ngx_http_limit_traffic_rate_filter_registered(r, lircf->shm_zone)) {
        /* e.g. after an internal redirect */
        return NGX_DECLINED;
    }

    ctx = lircf->shm_zone->data;

    vv = ngx_http_get_indexed_variable(r, ctx->index);

    if (vv == NULL || vv->not_found) {
        return NGX_DECLINED;
    }

    len = vv->len;

    if (len == 0) {
        return NGX_DECLINED;
    }

    if (len > 1024) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "the value of the \"%V\" variable "
                      "is more than 1024 bytes: \"%v\"",
                      &ctx->var, vv);
        return NGX_DECLINED;
    }

    hash = ngx_crc32_short(vv->data, len);

    cln = ngx_pool_cleanup_add(r->pool, sizeof(ngx_http_limit_traffic_rate_filter_cleanup_t));
    if (cln == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    ngx_http_limit_traffic_rate_filter_expire(ctx, shpool, 0);

    node = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key */

        do {
            lir = (ngx_http_limit_traffic_rate_filter_node_t *) &node->color;

            rc = ngx_memn2cmp(vv->data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
                if (lir->conn == 0) {
                    /* reuse an idle node, start a new window if it is paid */
                    ngx_queue_remove(&lir->idle);

                    if (ngx_time() >= lir->expire) {
                        lir->start_sec = ngx_time();
                        lir->sent_done = 0;
                    }
                }

                lir->conn++;
                ngx_http_limit_traffic_rate_filter_request_queue_t  *req;
                req = ngx_http_limit_traffic_rate_filter_alloc(ctx, shpool, sizeof(ngx_http_limit_traffic_rate_filter_request_queue_t));
                if (node == NULL) {
                    ngx_shmtx_unlock(&shpool->mutex);
                    return NGX_HTTP_SERVICE_UNAVAILABLE;
                }
                req->r = r;
                req->sent = 0;
                ngx_queue_insert_tail(&(lir->rq_top), &req->rq);
                goto done;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }

    n = offsetof(ngx_rbtree_node_t, color)
        + offsetof(ngx_http_limit_traffic_rate_filter_node_t, data)
        + len;

    node = ngx_http_limit_traffic_rate_filter_alloc(ctx, shpool, n);
    if (node == NULL) {
        ngx_shmtx_unlock(&shpool->mutex);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }

    lir = (ngx_http_limit_traffic_rate_filter_node_t *) &node->color;

    node->key = hash;
    lir->len = (u_short) len;
    lir->conn = 1;
    lir->start_sec = r->start_sec;
    lir->sent_done = 0;
    
    ngx_queue_init(&(lir->rq_top));
    ngx_http_limit_traffic_rate_filter_request_queue_t  *req;
    req = ngx_http_limit_traffic_rate_filter_alloc(ctx, shpool, sizeof(ngx_http_limit_traffic_rate_filter_request_queue_t));
    if (node == NULL) {
        ngx_shmtx_unlock(&shpool->mutex);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }
    req->r = r;
    req->sent = 0;
    ngx_queue_insert_tail(&(lir->rq_top), &req->rq);
    
    ngx_memcpy(lir->data, vv->data, len);

    ngx_rbtree_insert(ctx->rbtree, node);

done:

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "limit traffic rate: %08XD %d", node->key, lir->conn);

    /* the entry of this request was just added */
    q = ngx_queue_last(&lir->rq_top);

    ngx_shmtx_unlock(&shpool->mutex);

    cln->handler = ngx_http_limit_traffic_rate_filter_cleanup;
    lircln = cln->data;

    lircln->shm_zone = lircf->shm_zone;
    lircln->node = node;
    lircln->limit = lircf->limit_traffic_rate;
    lircln->limit_rate_after = 0;
    lircln->req = ngx_queue_data(q,
                       ngx_http_limit_traffic_rate_filter_request_queue_t, rq);

    return NGX_DECLINED;
}


static ngx_int_t
    ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    size_t                                   len;
    time_t                                   sec, t;
    uint32_t                                hash;
    ngx_int_t                               rc, num;
    ngx_slab_pool_t                *shpool;
    ngx_rbtree_node_t              *node, *sentinel;
    ngx_http_variable_value_t      *vv;
    ngx_http_limit_traffic_rate_filter_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_filter_node_t     *lir;
    ngx_http_limit_traffic_rate_filter_conf_t     *lircf;
    ngx_http_limit_traffic_rate_filter_req_ctx_t  *rctx;
    ngx_http_limit_traffic_rate_filter_cleanup_t  *lircln;
    off_t sent_sum = 0;
    off_t excess, delay, rate, min_rate;
    
    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, r->connection->log, 0, "limit traffic rate filter");
    
    lircf = ngx_http_get_module_loc_conf(r, ngx_http_limit_traffic_rate_filter_module);

    if (lircf->shm_zone == NULL) {
        return ngx_http_next_body_filter(r, in);
    }

    lircln = ngx_http_limit_traffic_rate_filter_registered(r, lircf->shm_zone);

    if (lircln == NULL) {
        /* e.g. "return", or an error before the preaccess phase */
        return ngx_http_next_body_filter(r, in);
    }

    ctx = lircf->shm_zone->data;

    vv = ngx_http_get_indexed_variable(r, ctx->index);

    if (vv == NULL || vv->not_found) {
        return ngx_http_next_body_filter(r, in);
    }

    len = vv->len;

    if (len == 0) {
        return ngx_http_next_body_filter(r, in);
    }

    if (len > 1024) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "the value of the \"%V\" variable "
                      "is more than 1024 bytes: \"%v\"",
                      &ctx->var, vv);
        return ngx_http_next_body_filter(r, in);
    }

    rctx = ngx_http_get_module_ctx(r, ngx_http_limit_traffic_rate_filter_module);

    if (rctx == NULL) {
        rctx = ngx_pcalloc(r->pool, sizeof(ngx_http_limit_traffic_rate_filter_req_ctx_t));
        if (rctx == NULL) {
            return NGX_ERROR;
        }

        /*
         * remember the rate set by the core limit_rate directive, the
         * $limit_rate variable or X-Accel-Limit-Rate, so that a stricter
         * per-request limit is still respected
         */

#if defined(nginx_version) && nginx_version >= 1017000
        {
        ngx_http_core_loc_conf_t  *clcf;

        clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

        if (!r->limit_rate_set) {
            rctx->limit_rate = ngx_http_complex_value_size(r, clcf->limit_rate, 0);

        } else {
            rctx->limit_rate = r->limit_rate;
        }

        if (!r->limit_rate_after_set) {
            rctx->limit_rate_after = ngx_http_complex_value_size(r,
                                                clcf->limit_rate_after, 0);

        } else {
            rctx->limit_rate_after = r->limit_rate_after;
        }
        }
#else
        rctx->limit_rate = r->limit_rate;
        rctx->limit_rate_after = r->limit_rate_after;
#endif

        ngx_http_set_ctx(r, rctx, ngx_http_limit_traffic_rate_filter_module);
    }

    /* the first limit_rate_after bytes are not limited, do not count them */
    lircln->limit_rate_after = rctx->limit_rate_after;

    hash = ngx_crc32_short(vv->data, len);

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    node = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key */

        do {
            lir = (ngx_http_limit_traffic_rate_filter_node_t *) &node->color;

            rc = ngx_memn2cmp(vv->data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
/*                r->limit_rate = lircf->limit_traffic_rate / lir->conn;
*/
                if (node != lircln->node || lir->conn == 0) {
                    /* the variable value has changed */
                    goto done;
                }

                ngx_queue_t *p = lir->rq_top.next;
                ngx_http_limit_traffic_rate_filter_request_queue_t * tr;
                for(; p != &lir->rq_top; ){
                    tr = ngx_queue_data(p, ngx_http_limit_traffic_rate_filter_request_queue_t, rq); 
                    if(tr == lircln->req) {
                        tr->sent = r->connection->sent
                                   - (off_t) lircln->limit_rate_after;
                        tr->sent = tr->sent > 0 ? tr->sent : 0;
                    }
                    sent_sum += tr->sent;
                    if(ngx_queue_last(&lir->rq_top) == p){
                        break;
                    }
                    p = ngx_queue_next(p);
                }

                sec = ngx_time() - lir->start_sec + 1;
                sec = sec > 0 ? sec : 1;
                num =lircf->limit_traffic_rate - sent_sum / sec;
                num =num / lir->conn + r->connection->sent / sec;

                num = num > 0 ? num : 1024;
                num = ((size_t)num >lircf->limit_traffic_rate) ? (ngx_int_t)lircf->limit_traffic_rate : num;

                /*
                 * short requests finish before they are slowed down, so
                 * also count the bytes of finished requests: if the total
                 * exceeds the limit for this window, choose a rate that
                 * makes the write filter wait until it is within the limit
                 */
                excess = lir->sent_done + sent_sum
                         - (off_t) lircf->limit_traffic_rate * sec;

                /* do not save up more than 1 second of unused bandwidth */
                if (excess < -(off_t) lircf->limit_traffic_rate) {
                    lir->sent_done += -excess
                                      - (off_t) lircf->limit_traffic_rate;
                }

                /* the first limit_rate_after bytes are not limited anyway */
                rate = r->connection->sent - (off_t) rctx->limit_rate_after;

                if (excess > 0 && rate >= 0) {
                    /* seconds until the total is within the limit again */
                    delay = excess / lircf->limit_traffic_rate + 1;

                    t = ngx_time() - r->start_sec + 1;
                    t = t > 0 ? t : 1;

                    /*
                     * the response header is sent from memory exactly as
                     * allowed; later the write filter may send up to a page
                     * more from a file, and then wait sent / rate seconds,
                     * so do not use a very low rate then
                     */
                    if ((off_t) r->header_size - r->connection->sent > t + 1) {
                        min_rate = 1;

                    } else {
                        min_rate = 1024;
                    }

                    rate = rate / (t + delay);
                    rate = rate > min_rate ? rate : min_rate;

                    if (rate < num) {
                        num = (ngx_int_t) rate;
                    }
                }

                if (rctx->limit_rate && (size_t) num > rctx->limit_rate) {
                    num = rctx->limit_rate;
                }

                r->limit_rate = num;

#if defined(nginx_version) && nginx_version >= 1017000
                /* prevent the write filter from resetting r->limit_rate */
                r->limit_rate_set = 1;
#endif
                
                ngx_log_debug5(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                     "limit traffic d:%z n:%O c:%d r:%z:::%z", lircf->limit_traffic_rate, 
                            sent_sum, lir->conn, lir->start_sec,r->limit_rate);
                
                goto done;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }
    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "rbtree search fail: %08XD %d", node->key, r->limit_rate);
    
done:

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "limit traffic rate: %08XD %d", node->key, r->limit_rate);

    ngx_shmtx_unlock(&shpool->mutex);

    return ngx_http_next_body_filter(r, in);
}

static ngx_int_t
ngx_http_limit_traffic_rate_filter_log_handler(ngx_http_request_t *r)
{
    off_t                                          sent;
    ngx_slab_pool_t                               *shpool;
    ngx_pool_cleanup_t                            *cln;
    ngx_http_limit_traffic_rate_filter_node_t     *lir;
    ngx_http_limit_traffic_rate_filter_cleanup_t  *lircln;

    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, r->connection->log, 0, 
                            "limit traffic rate log phase handler");

    if (r != r->main) {
        /* with log_subrequest, the registration belongs to the main request */
        return NGX_DECLINED;
    }

    /* count the bytes of the request as finished in each zone it is in */

    for (cln = r->pool->cleanup; cln; cln = cln->next) {

        if (cln->handler != ngx_http_limit_traffic_rate_filter_cleanup) {
            continue;
        }

        lircln = cln->data;

        if (lircln->req == NULL) {
            continue;
        }

        lir = (ngx_http_limit_traffic_rate_filter_node_t *) &lircln->node->color;
        shpool = (ngx_slab_pool_t *) lircln->shm_zone->shm.addr;

        sent = r->connection->sent - (off_t) lircln->limit_rate_after;

        ngx_shmtx_lock(&shpool->mutex);

        lir->sent_done += sent > 0 ? sent : 0;

        ngx_queue_remove(&lircln->req->rq);
        ngx_slab_free_locked(shpool, lircln->req);
        lircln->req = NULL;

        ngx_shmtx_unlock(&shpool->mutex);
    }

    return NGX_DECLINED;
}

static ngx_int_t
ngx_http_limit_traffic_rate_filter_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PREACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_limit_traffic_rate_filter_handler;

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_LOG_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_limit_traffic_rate_filter_log_handler;

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_limit_traffic_rate_body_filter;

    return NGX_OK;
}

static void *
ngx_http_limit_traffic_rate_filter_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_limit_traffic_rate_filter_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_limit_traffic_rate_filter_conf_t));
    if (conf == NULL) {
        return NGX_CONF_ERROR;
    }
    conf->limit_traffic_rate = NGX_CONF_UNSET_SIZE;
    return conf;
}

static char *
ngx_http_limit_traffic_rate_filter_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_limit_traffic_rate_filter_conf_t *prev = parent;
    ngx_http_limit_traffic_rate_filter_conf_t *conf = child;

    ngx_conf_merge_size_value(conf->limit_traffic_rate, prev->limit_traffic_rate, 0);

    return NGX_CONF_OK;
}

static void
ngx_http_limit_traffic_rate_filter_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t           **p;
    ngx_http_limit_traffic_rate_filter_node_t   *lirn, *lirnt;

    for ( ;; ) {

        if (node->key < temp->key) {

            p = &temp->left;

        } else if (node->key > temp->key) {

            p = &temp->right;

        } else { /* node->key == temp->key */

            lirn = (ngx_http_limit_traffic_rate_filter_node_t *) &node->color;
            lirnt = (ngx_http_limit_traffic_rate_filter_node_t *) &temp->color;

            p = (ngx_memn2cmp(lirn->data, lirnt->data, lirn->len, lirnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}

static ngx_int_t
ngx_http_limit_traffic_rate_filter_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_limit_traffic_rate_filter_ctx_t  *octx = data;

    size_t                      len;
    ngx_slab_pool_t            *shpool;
    ngx_rbtree_node_t          *sentinel;
    ngx_http_limit_traffic_rate_filter_ctx_t  *ctx;

    ctx = shm_zone->data;

    if (octx) {
        if (ngx_strcmp(ctx->var.data, octx->var.data) != 0) {
            ngx_log_error(NGX_LOG_EMERG, shm_zone->shm.log, 0,
                          "limit_traffic_rate_filter \"%V\" uses the \"%V\" variable "
                          "while previously it used the \"%V\" variable",
                          &shm_zone->shm.name, &ctx->var, &octx->var);
            return NGX_ERROR;
        }

        ctx->sh = octx->sh;
        ctx->rbtree = octx->rbtree;

        return NGX_OK;
    }

    shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        ctx->sh = shpool->data;
        ctx->rbtree = &ctx->sh->rbtree;

        return NGX_OK;
    }

    ctx->sh = ngx_slab_alloc(shpool, sizeof(ngx_http_limit_traffic_rate_filter_shctx_t));
    if (ctx->sh == NULL) {
        return NGX_ERROR;
    }

    shpool->data = ctx->sh;

    ctx->rbtree = &ctx->sh->rbtree;
    sentinel = &ctx->sh->sentinel;

    ngx_rbtree_init(ctx->rbtree, sentinel,
                    ngx_http_limit_traffic_rate_filter_rbtree_insert_value);

    ngx_queue_init(&ctx->sh->idle);

    len = sizeof(" in limit_traffic_rate_filter \"\"") + shm_zone->shm.name.len;

    shpool->log_ctx = ngx_slab_alloc(shpool, len);
    if (shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(shpool->log_ctx, " in limit_traffic_rate_filter \"%V\"%Z",
                &shm_zone->shm.name);

#if defined(nginx_version) && nginx_version >= 1005013
    /* idle nodes are freed on allocation failure, see filter_alloc() */
    shpool->log_nomem = 0;
#endif

    return NGX_OK;
}

static void
ngx_http_limit_traffic_rate_filter_cleanup(void *data)
{
    ngx_http_limit_traffic_rate_filter_cleanup_t  *lircln = data;

    ngx_slab_pool_t             *shpool;
    ngx_rbtree_node_t           *node;
    ngx_http_limit_traffic_rate_filter_ctx_t   *ctx;
    ngx_http_limit_traffic_rate_filter_node_t  *lir;

    ctx = lircln->shm_zone->data;
    shpool = (ngx_slab_pool_t *) lircln->shm_zone->shm.addr;
    node = lircln->node;
    lir = (ngx_http_limit_traffic_rate_filter_node_t *) &node->color;

    ngx_shmtx_lock(&shpool->mutex);

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, lircln->shm_zone->shm.log, 0,
                   "limit traffic rate cleanup: %08XD %d", node->key, lir->conn);

    if (lircln->req) {
        /* the log handler has not run */
        ngx_queue_remove(&lircln->req->rq);
        ngx_slab_free_locked(shpool, lircln->req);
        lircln->req = NULL;
    }

    lir->conn--;

    if (lir->conn == 0) {        
        ngx_queue_t *p = lir->rq_top.next;
        ngx_queue_t *c;
        ngx_http_limit_traffic_rate_filter_request_queue_t * tr;
        for(; p != &lir->rq_top; ){
            c = p;
            p = ngx_queue_next(p);

            if(ngx_queue_next(c) && ngx_queue_prev(c)){
                ngx_queue_remove(c);
            }
            tr = ngx_queue_data(c, ngx_http_limit_traffic_rate_filter_request_queue_t, rq); 
            if (!tr->r){
                ngx_slab_free_locked(shpool, tr);
            }

            if(ngx_queue_last(&lir->rq_top) == p){
                break;
            }
        }

        ngx_queue_init(&lir->rq_top);

        /*
         * keep the node while the bytes sent exceed the limit for its
         * window, or less than 1 second of unused bandwidth is left,
         * so that the next requests are limited too
         */

        if (lircln->limit) {
            lir->expire = lir->start_sec
                          + (lir->sent_done + lircln->limit - 1) / lircln->limit;
        } else {
            lir->expire = 0;
        }

        if (lir->expire > ngx_time()) {
            ngx_queue_insert_head(&ctx->sh->idle, &lir->idle);

        } else {
            ngx_rbtree_delete(ctx->rbtree, node);
            ngx_slab_free_locked(shpool, node);
        }
    }

    ngx_shmtx_unlock(&shpool->mutex);
}

static char *
ngx_http_limit_traffic_rate_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ssize_t                     n;
    ngx_str_t                  *value;
    ngx_shm_zone_t             *shm_zone;
    ngx_http_limit_traffic_rate_filter_ctx_t  *ctx;

    value = cf->args->elts;

    if (value[2].data[0] != '$') {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid variable name \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    value[2].len--;
    value[2].data++;

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_limit_traffic_rate_filter_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ctx->index = ngx_http_get_variable_index(cf, &value[2]);
    if (ctx->index == NGX_ERROR) {
        return NGX_CONF_ERROR;
    }

    ctx->var = value[2];

    n = ngx_parse_size(&value[3]);

    if (n == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid size of limit_traffic_rate_zone \"%V\"", &value[3]);
        return NGX_CONF_ERROR;
    }

    if (n < (ngx_int_t) (8 * ngx_pagesize)) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "limit_traffic_rate_zone \"%V\" is too small", &value[1]);
        return NGX_CONF_ERROR;
    }


    shm_zone = ngx_shared_memory_add(cf, &value[1], n,
                                     &ngx_http_limit_traffic_rate_filter_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (shm_zone->data) {
        ctx = shm_zone->data;

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                        "limit_traffic_rate_zone \"%V\" is already bound to variable \"%V\"",
                        &value[1], &ctx->var);
        return NGX_CONF_ERROR;
    }

    shm_zone->init = ngx_http_limit_traffic_rate_filter_init_zone;
    shm_zone->data = ctx;

    return NGX_CONF_OK;
}


static char *
ngx_http_limit_traffic_rate(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_limit_traffic_rate_filter_conf_t  *lircf = conf;

    ngx_int_t   n;
    ngx_str_t  *value;

    if (lircf->shm_zone) {
        return "is duplicate";
    }

    value = cf->args->elts;

    lircf->shm_zone = ngx_shared_memory_add(cf, &value[1], 0,
                                           &ngx_http_limit_traffic_rate_filter_module);
    if (lircf->shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    n = ngx_parse_size(&value[2]);
    
    if (n == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid size of limit_traffic_rate \"%V\"", &value[3]);
        return NGX_CONF_ERROR;
    }

    if (n <= 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid size of limit_traffic_rate \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    lircf->limit_traffic_rate= n;

    return NGX_CONF_OK;
}

