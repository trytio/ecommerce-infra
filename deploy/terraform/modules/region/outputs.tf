output "vpc_id"            { value = aws_vpc.main.id }
output "route_table_id"    { value = aws_route_table.public.id }
output "server_public_ip"  { value = aws_instance.server.public_ip }
output "server_private_ip" { value = aws_instance.server.private_ip }
output "client_public_ips" { value = aws_instance.client[*].public_ip }
output "router_public_ip"  { value = var.include_router ? aws_instance.router[0].public_ip : "" }
