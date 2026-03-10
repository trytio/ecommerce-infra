# ─── US ────────────────────────────────────────────────────
output "us_server_public_ip" {
  value = module.us.server_public_ip
}

output "us_server_private_ip" {
  value = module.us.server_private_ip
}

output "us_client_public_ips" {
  value = module.us.client_public_ips
}

output "us_router_public_ip" {
  value = module.us.router_public_ip
}

# ─── AU ────────────────────────────────────────────────────
output "au_server_public_ip" {
  value = module.au.server_public_ip
}

output "au_server_private_ip" {
  value = module.au.server_private_ip
}

output "au_client_public_ips" {
  value = module.au.client_public_ips
}

# ─── Endpoints ─────────────────────────────────────────────
output "endpoints" {
  value = {
    us_api          = "http://${module.us.server_public_ip}:4646"
    au_api          = "http://${module.au.server_public_ip}:4646"
    us_frontend_lb  = "http://${module.us.server_public_ip}:8080"
    us_api_lb       = "http://${module.us.server_public_ip}:8081"
    au_frontend_lb  = "http://${module.au.server_public_ip}:8080"
    au_api_lb       = "http://${module.au.server_public_ip}:8081"
    router          = module.us.router_public_ip != "" ? "http://${module.us.router_public_ip}:8080" : "n/a"
    router_mgmt     = module.us.router_public_ip != "" ? "http://${module.us.router_public_ip}:8443" : "n/a"
  }
}
