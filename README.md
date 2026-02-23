# E-Commerce Stack for Carlos GitOps

A production-ready e-commerce microservices stack designed for [Carlos](https://github.com/trytio/carlos) GitOps deployments with Kustomize-style overlays and multi-stage promotion.

## Architecture

```
                    ┌─────────────┐
                    │  Storefront │  (nginx)
                    │   :80       │
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │ API Gateway │  (http-echo :8080)
                    └──────┬──────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
    ┌───────┴───────┐ ┌────┴────┐ ┌───────┴───────┐
    │Product Catalog│ │  Cart   │ │ Order Service │
    │   :8081       │ │ :8082   │ │    :8083      │
    └───────┬───────┘ └────┬────┘ └───────┬───────┘
            │              │              │
            └──────────────┼──────────────┘
                           │
              ┌────────────┼────────────┐
              │                         │
       ┌──────┴──────┐          ┌───────┴───────┐
       │    Cache    │          │   Database    │
       │ Redis :6379 │          │ Postgres :5432│
       └─────────────┘          └───────────────┘
```

## Services

| Service | Image | Port | Health Check | Description |
|---------|-------|------|--------------|-------------|
| **storefront** | nginx:alpine | 80 | HTTP `/` | Public-facing web UI |
| **api-gateway** | http-echo | 8080 | HTTP `/` | Request routing & rate limiting |
| **product-catalog** | http-echo | 8081 | HTTP `/` | Product listings & search |
| **cart-service** | http-echo | 8082 | HTTP `/` | Shopping cart sessions |
| **order-service** | http-echo | 8083 | HTTP `/` | Checkout & payment processing |
| **cache** | redis:7-alpine | 6379 | TCP | Shared session & product cache |
| **database** | postgres:16-alpine | 5432 | TCP | Persistent product & order data |

## Directory Structure

```
├── base/                          # Canonical job specs
│   ├── storefront.yaml
│   ├── api-gateway.yaml
│   ├── product-catalog.yaml
│   ├── cart-service.yaml
│   ├── order-service.yaml
│   ├── cache.yaml
│   └── database.yaml
├── overlays/
│   ├── dev/                       # Dev: 1 replica, debug, mock payments
│   │   ├── storefront.yaml
│   │   ├── api-gateway.yaml
│   │   ├── product-catalog.yaml
│   │   ├── cart-service.yaml
│   │   ├── order-service.yaml
│   │   ├── cache.yaml
│   │   └── database.yaml
│   ├── staging/                   # Staging: 2 replicas, test payments
│   │   └── ...
│   └── prod/                      # Prod: 3+ replicas, autoscaling, live payments
│       └── ...
```

## Environment Differences

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| Replicas | 1 | 2 | 3+ |
| Autoscaling | No | No | Yes (2-10) |
| CPU (storefront) | 100 MHz | 200 MHz | 500 MHz |
| Memory (storefront) | 64 MB | 128 MB | 256 MB |
| Log Level | debug | info | warn |
| Payment Gateway | mock | stripe-test | stripe |
| DB Name | `*_dev` | `*_staging` | `*_prod` |
| VRE Replicas | 2 | 2 | 3 + zstd compression |
| Placement | spread | spread | spread |

## Quick Start

### 1. Preview a Merged Spec

```bash
# See what dev storefront looks like after overlay merge
carlos build base/storefront.yaml -o overlays/dev/storefront.yaml

# See prod order-service with autoscaling and 3x replication
carlos build base/order-service.yaml -o overlays/prod/order-service.yaml
```

### 2. Register with Carlos GitOps

```bash
curl -X POST http://YOUR_SERVER:4646/v1/gitops/apps \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ecommerce",
    "repo_url": "https://github.com/trytio/carlos-ecommerce-stack.git",
    "branch": "main",
    "base_path": "base",
    "stages": [
      {"name": "dev", "overlay_path": "overlays/dev"},
      {"name": "staging", "overlay_path": "overlays/staging"},
      {"name": "prod", "overlay_path": "overlays/prod"}
    ],
    "poll_interval": 60,
    "auto_sync": true
  }'
```

### 3. Check Sync Status

```bash
curl -s http://YOUR_SERVER:4646/v1/gitops/status | python3 -m json.tool
```

### 4. Promote Between Stages

```bash
# After testing in dev, promote to staging
curl -X POST http://YOUR_SERVER:4646/v1/gitops/promote \
  -H "Content-Type: application/json" \
  -d '{"app": "ecommerce", "from_stage": "dev", "to_stage": "staging"}'

# After staging validation, promote to production
curl -X POST http://YOUR_SERVER:4646/v1/gitops/promote \
  -H "Content-Type: application/json" \
  -d '{"app": "ecommerce", "from_stage": "staging", "to_stage": "prod"}'
```

### 5. View Promotion History

```bash
curl -s http://YOUR_SERVER:4646/v1/gitops/promotions | python3 -m json.tool
```

## Promotion Workflow

```
  Git Push → Auto-sync (dev) → Manual promote → Staging → Manual promote → Prod
     │              │                │                │              │
     │         ┌────┴────┐     ┌────┴────┐      ┌───┴───┐    ┌────┴────┐
     │         │ 1 replica│     │2 replicas│      │Testing│    │3+ replicas│
     │         │ debug   │     │ info    │      │stripe │    │autoscale│
     │         │ mock pay│     │test pay │      │ test  │    │live pay │
     │         └─────────┘     └─────────┘      └───────┘    └─────────┘
```

1. **Push to main** → Carlos auto-syncs dev stage (merges `base/ + overlays/dev/`)
2. **Test in dev** → Verify services, mock payments, debug logs
3. **Promote to staging** → Applies `base/ + overlays/staging/` (2 replicas, test payments)
4. **Validate staging** → Run integration tests, verify staging DB
5. **Promote to prod** → Applies `base/ + overlays/prod/` (autoscaling, live payments, 3x VRE)

## How Overlays Work

Carlos uses Kustomize-style strategic merge:

- **Maps (objects)**: Merged recursively — overlay keys win, base-only keys preserved
- **Arrays (lists)**: Overlay replaces the entire array
- **Scalars**: Overlay wins

This means overlays must include the **complete task definition** (image, ports, health checks)
since the `tasks` array is replaced wholesale. This is intentional — it ensures each environment
is fully self-describing and auditable.

## Verifying Services

After deployment, check the service catalog:

```bash
# List all registered services
curl -s http://YOUR_SERVER:4646/v1/services | python3 -m json.tool

# Check node placement
curl -s http://YOUR_SERVER:4646/v1/allocations | python3 -m json.tool

# Check VRE replication (for order-service and database volumes)
curl -s http://YOUR_SERVER:4646/v1/vre/overview | python3 -m json.tool
```

## Customization

To adapt this stack for your own e-commerce platform:

1. **Replace images**: Swap `hashicorp/http-echo` with your actual service images
2. **Update ports**: Match your application's actual listening ports
3. **Configure health checks**: Set proper health check paths (`/health`, `/ready`)
4. **Set real credentials**: Use Carlos secrets (`carlos secret set`) instead of env vars
5. **Tune resources**: Adjust CPU/memory based on your load testing results
6. **Add volumes**: Mount persistent storage where needed

## Features Exercised

This stack demonstrates these Carlos capabilities:

- **GitOps with Kustomize overlays** — Base + environment-specific patches
- **Multi-stage promotion** — dev → staging → prod pipeline
- **HTTP & TCP health checks** — Automatic service registration on health
- **Spread placement** — Services distributed across nodes
- **Horizontal autoscaling** — CPU-based scaling in production
- **VRE replication** — Replicated volumes for order data and database
- **VRE compression** — zstd compression in production for efficient sync
- **Rolling updates** — Zero-downtime deployments with rollback
- **Critical task marking** — Database and order service marked critical
- **Service catalog** — Auto-registered services with tag-based discovery
