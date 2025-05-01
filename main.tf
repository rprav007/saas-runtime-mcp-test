// main.tf

// Configure the Google Cloud provider
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

// -----------------------------------------------------------------------------
// INPUT VARIABLES
// -----------------------------------------------------------------------------

variable "gcp_project_id" {
  description = "The Google Cloud project ID where resources will be created."
  type        = string
}

variable "gcp_region" {
  description = "The Google Cloud region for deploying the Cloud Run service."
  type        = string
  default     = "us-central1" // Matches --region from gcloud command
}

variable "service_name" {
  description = "The name for the Cloud Run service for the MCP Toolbox."
  type        = string
  default     = "new-toolbox" // Matches service name from gcloud command
}

variable "mcp_toolbox_image" {
  description = "The Docker container image for the MCP Toolbox. Corresponds to $IMAGE in the gcloud command."
  type        = string
  // Official MCP Toolbox for Databases image. You can replace this if you have a custom image.
  default = "us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:latest"
}

variable "tools_yaml_secret_name" {
  description = "The name of the secret in Secret Manager for tools.yaml."
  type        = string
  default     = "tools" // Matches secret name from --set-secrets in gcloud command
}

variable "cloud_run_service_account_id" {
  description = "The ID (name part) of the service account for Cloud Run (e.g., 'toolbox-identity')."
  type        = string
  default     = "toolbox-identity" // Matches --service-account from gcloud command
}

variable "allow_unauthenticated_invocations" {
  description = "If true, allows unauthenticated (public) access to the Cloud Run service (equivalent to --allow-unauthenticated). Set to false for private services."
  type        = bool
  default     = true // WARNING: Review security implications. Matches the commented-out --allow-unauthenticated intent.
}

variable "vpc_network_name" {
  description = "The name of the VPC network for Direct VPC Egress (e.g., 'default')."
  type        = string
  default     = "default" // Matches --network from gcloud command
}

variable "vpc_subnet_name" {
  description = "The name of the VPC subnetwork for Direct VPC Egress (e.g., 'default')."
  type        = string
  default     = "default" // Matches --subnet from gcloud command
}

// -----------------------------------------------------------------------------
// CLOUD RUN SERVICE
// -----------------------------------------------------------------------------

// Deploy the MCP Toolbox as a Cloud Run v2 service
resource "google_cloud_run_v2_service" "mcp_toolbox_service" {
  name     = var.service_name
  location = var.gcp_region
  ingress  = "INGRESS_TRAFFIC_ALL" // Defines who can reach the service (all, internal, internal-load-balancer)

  // Configuration for the service template
  template {
    // Set the service account for the Cloud Run service
    service_account = "${var.cloud_run_service_account_id}@${var.gcp_project_id}.iam.gserviceaccount.com"

    // Define the container(s) to run
    containers {
      image = var.mcp_toolbox_image // Use the specified MCP Toolbox image
      ports {
        container_port = 8080 // The MCP Toolbox typically listens on port 8080
      }

      // Arguments passed to the container, matching the --args from gcloud command
      args = [
        "--tools-file=/app/tools.yaml", // Path inside the container where tools.yaml will be mounted
        "--address=0.0.0.0",            // Listen on all network interfaces
        "--port=8080"                   // Listen on port 8080
      ]

      // Mount the tools.yaml file from the secret volume
      // This corresponds to --set-secrets "/app/tools.yaml=tools:latest"
      
      volume_mounts {
        name       = "tools-config-volume" // Must match a volume name defined below
        mount_path = "/app"      // Mount path as specified in --set-secrets
        #read_only  = true                   // Mount as read-only
      }
      

      // Optional: Configure resource requests and limits
      // resources {
      //   limits = {
      //     cpu    = "1000m" // 1 CPU core
      //     memory = "512Mi" // 512 MB of memory
      //   }
      // }
    }

    // Define the volume that sources data from Secret Manager
    volumes {
      name = "tools-config-volume" // Name for the volume, referenced in volume_mounts
      secret {
        secret = "tools" // ID of the secret (e.g., "tools")
        // Specify which version of the secret to use and how to map it
        // Cloud Run uses the "latest" version by default if a specific version isn't pinned here.
        // The gcloud command uses "tools:latest", so we reference the secret name directly.
        items {
          version = "latest"     // Explicitly use the latest version, matching gcloud behavior
          path    = "tools.yaml" // The filename inside the volume
        }
        #default_mode = 0o400 // Permissions for the mounted file (read-only for owner)
      }
    }

    // VPC Access Configuration for Direct VPC Egress
    // Corresponds to --network and --subnet flags in gcloud command
    vpc_access {
      network_interfaces {
        network    = var.vpc_network_name
        subnetwork = var.vpc_subnet_name
        // tags = [] // Optional: List of network tags for the Cloud Run instances
      }
      egress = "ALL_TRAFFIC" // Allows all outbound traffic through the VPC.
                             // Change to "PRIVATE_RANGES_ONLY" if needed.
    }

    // Optional: Configure scaling behavior
    // scaling {
    //   min_instance_count = 0
    //   max_instance_count = 5
    // }
  }

  // Optional: Define traffic splitting for multiple revisions (not used in this basic setup)
  // traffic {
  //   type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
  //   percent = 100
  // }
  /*
  depends_on = [
    #google_secret_manager_secret_version.tools_yaml_secret_version
  ]
  */
}

// -----------------------------------------------------------------------------
// IAM FOR PUBLIC ACCESS (OPTIONAL)
// -----------------------------------------------------------------------------

// Grant public access to the Cloud Run service if allow_unauthenticated_invocations is true
// WARNING: This makes your service accessible to anyone on the internet.
// For production or sensitive services, you should implement proper authentication.
resource "google_cloud_run_v2_service_iam_member" "allow_unauthenticated" {
  count    = var.allow_unauthenticated_invocations ? 1 : 0 // Create this resource only if the variable is true
  project  = google_cloud_run_v2_service.mcp_toolbox_service.project
  location = google_cloud_run_v2_service.mcp_toolbox_service.location
  name     = google_cloud_run_v2_service.mcp_toolbox_service.name
  role     = "roles/run.invoker" // Role that allows invoking the Cloud Run service
  member   = "allUsers"          // Special identifier for "anyone"

  depends_on = [google_cloud_run_v2_service.mcp_toolbox_service]
}

// -----------------------------------------------------------------------------
// OUTPUTS
// -----------------------------------------------------------------------------

output "mcp_toolbox_service_url" {
  description = "The URL of the deployed MCP Toolbox Cloud Run service."
  value       = google_cloud_run_v2_service.mcp_toolbox_service.uri
}
/*
output "mcp_toolbox_secret_name_used" {
  description = "The name of the Secret Manager secret used for tools.yaml."
  value       = google_secret_manager_secret.tools_yaml_secret.secret_id // This will output the actual secret_id used.
}
*/
output "cloud_run_service_account_used" {
  description = "The full email of the service account used by the Cloud Run service."
  value       = google_cloud_run_v2_service.mcp_toolbox_service.template[0].service_account
}

output "vpc_network_configured" {
  description = "The VPC network configured for Direct VPC Egress."
  value       = var.vpc_network_name
}

output "vpc_subnet_configured" {
  description = "The VPC subnetwork configured for Direct VPC Egress."
  value       = var.vpc_subnet_name
}


