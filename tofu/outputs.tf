output "cluster_name" {
  description = "Name of the k3d cluster"
  value       = var.k3d_cluster_name
}

output "postgres_host" {
  description = "PostgreSQL connection host"
  value       = "localhost"
}

output "postgres_port" {
  description = "PostgreSQL connection port"
  value       = var.postgres_port
}

output "postgres_connection_string" {
  description = "PostgreSQL connection string"
  value       = "postgresql://postgres:${var.postgres_password}@localhost:${var.postgres_port}/app"
  sensitive   = true
}

output "postgrest_db_uri" {
  description = "PostgREST database URI used by the authenticator role"
  value       = "postgresql://authenticator:${var.postgrest_authenticator_password}@postgres-infra-takehome:${var.postgres_port}/postgrest"
  sensitive   = true
}
