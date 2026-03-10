# ==============================================================================
# Providers
# ==============================================================================

provider "docker" {}

provider "postgresql" {
  host     = "localhost"
  port     = var.postgres_port
  username = "postgres"
  password = var.postgres_password
  sslmode  = "disable"
}



# ==============================================================================
# k3d Cluster
# ==============================================================================

resource "terraform_data" "k3d_cluster" {
  input = {
    name  = var.k3d_cluster_name
    image = "rancher/k3s:${var.k3s_version}"
  }

  provisioner "local-exec" {
    command = "k3d cluster create ${self.input.name} --image ${self.input.image} --servers 1 --agents 0 -p '8080:80@loadbalancer'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.input.name}"
  }
}

# ==============================================================================
# PostgreSQL Container
# ==============================================================================

resource "docker_image" "postgres" {
  name         = "postgres:16-alpine"
  keep_locally = true
}

resource "docker_volume" "postgres_data" {
  name = "postgres-infra-takehome-data"
}

resource "docker_container" "postgres" {
  name  = "postgres-infra-takehome"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=app",
  ]

  ports {
    internal = 5432
    external = var.postgres_port
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name = data.docker_network.k3d.name
  }

  restart = "unless-stopped"
}

# Attach the Postgres container to the k3d network so pods can reach it
data "docker_network" "k3d" {
  name       = "k3d-${var.k3d_cluster_name}"
  depends_on = [terraform_data.k3d_cluster]
}

# ==============================================================================
# PostgREST Database (Task 1)
# ==============================================================================

# Wait for Postgres to be fully ready before creating database objects
resource "terraform_data" "postgres_ready" {
  depends_on = [docker_container.postgres]

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 30); do
        docker exec postgres-infra-takehome pg_isready -U postgres && exit 0
        echo "Waiting for PostgreSQL to be ready... ($i/30)"
        sleep 2
      done
      echo "PostgreSQL did not become ready in time" && exit 1
    EOT
  }
}

resource "postgresql_database" "postgrest" {
  name       = "postgrest"
  depends_on = [terraform_data.postgres_ready]
}

# -- Roles -------------------------------------------------------------------

# web_anon: anonymous role for unauthenticated API requests
resource "postgresql_role" "web_anon" {
  name       = "web_anon"
  login      = false
  depends_on = [postgresql_database.postgrest]
}

# authenticator: the role PostgREST uses to connect (can switch to web_anon)
resource "postgresql_role" "authenticator" {
  name     = "authenticator"
  login    = true
  password = var.postgrest_authenticator_password
  roles    = [postgresql_role.web_anon.name]

  depends_on = [postgresql_database.postgrest]
}

# app_admin: superuser for database administration
resource "postgresql_role" "app_admin" {
  name       = "app_admin"
  login      = true
  superuser  = true
  password   = var.postgres_password
  depends_on = [postgresql_database.postgrest]
}

# -- Schema grants for web_anon on the postgrest database --------------------

# Connect to the "postgrest" DB to manage grants
provider "postgresql" {
  alias    = "postgrest_db"
  host     = "localhost"
  port     = var.postgres_port
  username = "postgres"
  password = var.postgres_password
  database = "postgrest"
  sslmode  = "disable"
}

resource "postgresql_grant" "web_anon_usage" {
  provider    = postgresql.postgrest_db
  database    = "postgrest"
  role        = postgresql_role.web_anon.name
  schema      = "public"
  object_type = "schema"
  privileges  = ["USAGE"]
}

resource "postgresql_default_privileges" "web_anon_tables" {
  provider    = postgresql.postgrest_db
  database    = "postgrest"
  role        = postgresql_role.web_anon.name
  schema      = "public"
  owner       = "postgres"
  object_type = "table"
  privileges  = ["SELECT"]
}

# ==============================================================================
# Kubernetes – Namespace & Secret (Task 2)
# Uses kubectl via local-exec because the kubernetes provider cannot initialise
# before the k3d cluster has been provisioned (chicken-and-egg).
# ==============================================================================

resource "terraform_data" "postgrest_namespace_and_secret" {
  input = {
    cluster_name = var.k3d_cluster_name
    db_uri       = "postgresql://authenticator:${var.postgrest_authenticator_password}@postgres-infra-takehome:5432/postgrest"
  }

  depends_on = [terraform_data.k3d_cluster]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context k3d-${self.input.cluster_name} create namespace postgrest --dry-run=client -o yaml | kubectl --context k3d-${self.input.cluster_name} apply -f -
      kubectl --context k3d-${self.input.cluster_name} -n postgrest create secret generic postgrest-secrets \
        --from-literal=PGRST_DB_URI='${self.input.db_uri}' \
        --dry-run=client -o yaml | kubectl --context k3d-${self.input.cluster_name} apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --context k3d-${self.input.cluster_name} delete namespace postgrest --ignore-not-found"
  }
}
