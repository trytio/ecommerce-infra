terraform {
  required_providers {
    carlos = {
      source = "registry.terraform.io/trytio/carlos"
    }
  }
}

variable "stack_name" {
  type = string
}

# ─── Secrets ───────────────────────────────────────────────
resource "carlos_secret" "db_password" {
  name  = "db_password"
  value = "ecommerce-prod-pg-2026"
}

# ─── Frontend (nginx) with VRE-aware LB ───────────────────
resource "carlos_job" "frontend" {
  name     = var.stack_name
  job_type = "service"

  update {
    max_parallel         = 1
    stagger_secs         = 10
    health_deadline_secs = 60
    on_failure           = "rollback"
    auto_revert          = true
  }

  group {
    name     = "frontend"
    count    = 2
    strategy = "spread"

    scaling {
      min      = 1
      max      = 4
      metric   = "cpu"
      target   = 70
      cooldown = 30
    }

    task {
      name   = "nginx"
      driver = "docker"
      image  = "docker.io/library/nginx:alpine"

      port {
        label     = "http"
        container = 80
        host      = 0
      }

      resources {
        cpu    = 100
        memory = 64
      }

      load_balancer {
        port         = 8080
        target       = "http"
        algorithm    = "round_robin"
        vre_aware    = true
        bind_address = "0.0.0.0"
      }

      health_check {
        type       = "http"
        path       = "/"
        port_label = "http"
        interval   = 10
        timeout    = 5
      }
    }
  }

  group {
    name     = "api"
    count    = 2
    strategy = "spread"

    task {
      name   = "httpd"
      driver = "docker"
      image  = "docker.io/library/httpd:alpine"

      port {
        label     = "api"
        container = 80
        host      = 0
      }

      resources {
        cpu    = 150
        memory = 128
      }

      load_balancer {
        port         = 8081
        target       = "api"
        algorithm    = "round_robin"
        vre_aware    = true
        bind_address = "0.0.0.0"
      }

      health_check {
        type       = "http"
        path       = "/"
        port_label = "api"
        interval   = 10
        timeout    = 5
      }
    }
  }

  group {
    name     = "database"
    count    = 1
    strategy = "bin_pack"

    volume {
      name        = "redis-data"
      volume_type = "replicated"

      replication {
        replicas           = 2
        sync_interval_secs = 15
      }
    }

    task {
      name   = "redis"
      driver = "docker"
      image  = "docker.io/library/redis:alpine"

      port {
        label     = "redis"
        container = 6379
        host      = 0
      }

      mount {
        volume      = "redis-data"
        destination = "/data"
      }

      resources {
        cpu    = 200
        memory = 512
      }

      health_check {
        type     = "tcp"
        port     = 6379
        interval = 10
        timeout  = 3
      }

      secrets = [carlos_secret.db_password.name]
    }
  }

  group {
    name     = "worker"
    count    = 1
    strategy = "bin_pack"

    task {
      name   = "processor"
      driver = "docker"
      image  = "docker.io/library/redis:alpine"

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}

output "job_id" {
  value = carlos_job.frontend.id
}
