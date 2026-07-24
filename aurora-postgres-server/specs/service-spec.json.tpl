{
  "name": "Aurora PostgreSQL Server",
  "slug": "aurora-postgres-server",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["connect"],
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["instance_class"],
      "properties": {
        "instance_class": {
          "type": "string",
          "title": "Instance Class",
          "default": "db.r6g.large",
          "description": "Aurora instance class applied to every cluster instance (writer and readers)",
          "editableOn": ["create", "update"],
          "order": 1
        },
        "reader_count": {
          "type": "number",
          "title": "Reader Count",
          "default": 0,
          "minimum": 0,
          "maximum": 15,
          "description": "Number of Aurora reader instances in addition to the writer",
          "editableOn": ["create", "update"],
          "order": 2
        },
        "postgres_version": {
          "type": "string",
          "title": "Aurora PostgreSQL Version",
          "default": "16",
          "enum": ["13", "14", "15", "16"],
          "description": "Aurora PostgreSQL major version (cannot be changed after creation)",
          "editableOn": ["create"],
          "order": 3
        },
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora cluster writer endpoint (auto-populated after creation)",
          "order": 4
        },
        "hostname_reader": {
          "type": "string",
          "title": "Reader Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora cluster reader endpoint (auto-populated after creation)",
          "order": 5
        },
        "port": {
          "type": "number",
          "title": "Port",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora port (auto-populated after creation)",
          "order": 6
        },
        "db_cluster_identifier": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal AWS Aurora cluster identifier"
        },
        "master_secret_arn": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "ARN of the Secrets Manager secret holding master credentials (internal use)"
        },
        "engine_family": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal marker used by aurora-postgres-db auto-discovery to disambiguate this server from other database dependency services (always \"aurora-postgresql\")"
        }
      }
    },
    "values": {}
  }
}
