# Infrastructure for the Yandex Cloud Managed Service for MySQL, Managed Service for Greenplum® and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/mmy-to-mgp
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/mmy-to-mgp
#
# Specify the following settings:

locals {
  # Settings for Managed Service for Greenplum® cluster:
  gp_version       = "" # Desired version of Greenplum®. For available versions, see the documentation main page: https://cloud.yandex.com/en/docs/managed-greenplum/.
  gp_user_password = "" # User password

  # Settings for Managed Service for MySQL cluster:
  mysql_version       = "" # Desired version of MySQL. For available versions, see the documentation main page: https://cloud.yandex.com/en/docs/managed-mysql/.
  mysql_user_password = "" # User password

  # Specify these settings ONLY AFTER the clusters are created. Then run "terraform apply" command again.
  # You should set up endpoint using the GUI to obtain its ID
  target_endpoint_id = "" # Set the target endpoint ID.
  transfer_enabled   = 0  # Set to 1 to enable Transfer

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mmy-mgp-network"   # Name of the network
  subnet_name           = "subnet-a"          # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"       # CIDR block for the subnet in the ru-central1-a availability zone
  security_group_name   = "security-group"    # Name of the security group
  gp_cluster_name       = "greenplum-cluster" # Name of the Greenplum® cluster
  gp_username           = "mgp_user"          # Name of the Greenplum® username
  mysql_cluster_name    = "mysql-cluster"     # Name of the MySQL cluster
  mysql_db_name         = "mmy_db"            # Name of the MySQL cluster database
  mysql_username        = "mmy_user"          # Name of the MySQL cluster username
}

# Network resources

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for Greenplum® and Managed Service for MySQL clusters"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for Greenplum® and Managed Service for MySQL clusters"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allow incoming traffic from the Internet"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "The rule allows connections to the Managed Service for MySQL cluster from the Internet"
    protocol       = "TCP"
    port           = 3306
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "The rule allows all outgoing traffic"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# MySQL cluster

resource "yandex_mdb_mysql_cluster" "mysql-cluster" {
  description        = "Managed Service for MySQL cluster"
  name               = local.mysql_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  version            = local.mysql_version
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  resources {
    resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
    disk_size          = 10         # GB
    disk_type_id       = "network-hdd"
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
    assign_public_ip = true # Required for connection from the Internet
  }
}

# Database of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_database" "mmy-db" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.mysql_db_name
}

# User of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_user" "mmy-user" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.mysql_username
  password   = local.mysql_user_password
  permission {
    database_name = yandex_mdb_mysql_database.mmy-db.name
    roles         = ["ALL"]
  }

  global_permissions = ["REPLICATION_CLIENT", "REPLICATION_SLAVE"]
}

# Greenplum® cluster

resource "yandex_mdb_greenplum_cluster" "mgp-cluster" {
  description        = "Managed Service for Greenplum® cluster"
  name               = local.gp_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  zone               = "ru-central1-a"
  subnet_id          = yandex_vpc_subnet.subnet-a.id
  assign_public_ip   = true
  version            = local.gp_version
  master_host_count  = 2
  segment_host_count = 2
  segment_in_host    = 1
  master_subcluster {
    resources {
      resource_preset_id = "s2.medium" # 8 vCPU, 32 GB RAM
      disk_size          = 100         # GB
      disk_type_id       = "local-ssd"
    }
  }
  segment_subcluster {
    resources {
      resource_preset_id = "s2.medium" # 8 vCPU, 32 GB RAM
      disk_size          = 100         # GB
      disk_type_id       = "local-ssd"
    }
  }

  access {
    data_transfer = true
  }

  user_name     = local.gp_username
  user_password = local.gp_user_password

  security_group_ids = [yandex_vpc_security_group.security-group.id]
}

# Transfer

resource "yandex_datatransfer_endpoint" "mmy-source" {
  description = "Source endpoint for MySQL cluster"
  name        = "mmy-source"
  settings {
    mysql_source {
      connection {
        mdb_cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
      }
      database = local.mysql_db_name
      user     = local.mysql_username
      password {
        raw = local.mysql_user_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "mysql-gp-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Managed Service for MySQL to the Managed Service for Greenplum®"
  name        = "transfer-from-mmy-to-mgp"
  source_id   = yandex_datatransfer_endpoint.mmy-source.id
  target_id   = local.target_endpoint_id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source cluster and start replication
}