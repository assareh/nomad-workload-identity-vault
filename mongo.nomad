# doc ref https://developer.hashicorp.com/nomad/docs/job-specification/identity#workload-identities-for-vault
# if you comment out the identity block, the default identity defined in the nomad server config is used

job "mongo" {
  namespace = "default"

  group "db" {
    network {
      port "db" {
        to = 27017
      }
    }

    task "mongo" {
      driver = "docker"

      config {
        image = "mongo:7"
        ports = ["db"]
      }

      vault {}

    //   identity {
    //     name = "vault_default"
    //     aud  = ["vault.io"]
    //     ttl  = "1h"
    //   }

      template {
        data        = <<EOF
{{with secret "secret/data/default/mongo/config"}}
MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD={{.Data.data.root_password}}
{{end}}
EOF
        destination = "secrets/env"
        env         = true
      }
    }
  }
}
