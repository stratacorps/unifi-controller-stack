#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the UniFi Mongo user on first Mongo init.
# Expected env vars:
#   MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD
#   MONGO_USER, MONGO_PASS
# Optional:
#   MONGO_AUTHSOURCE (default: admin)
#   MONGO_DBNAME     (default: unifi)

AUTHSOURCE="${MONGO_AUTHSOURCE:-admin}"
DBNAME="${MONGO_DBNAME:-unifi}"
USER="${MONGO_USER}"
PASS="${MONGO_PASS}"

# UniFi commonly uses these DBs:
DB_STAT="${DBNAME}_stat"      # unifi_stat
DB_AUDIT="${DBNAME}_audit"    # unifi_audit

mongosh --username "$MONGO_INITDB_ROOT_USERNAME" \
        --password "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin <<EOS
const authDb = db.getSiblingDB("${AUTHSOURCE}");

const user = "${USER}";
const pwd  = "${PASS}";

const roles = [
  { role: "readWrite", db: "${DBNAME}" },
  { role: "readWrite", db: "${DB_STAT}" },
  { role: "readWrite", db: "${DB_AUDIT}" }
];

const existing = authDb.getUser(user);

if (existing == null) {
  authDb.createUser({ user: user, pwd: pwd, roles: roles });
  print("Created user '" + user + "' with roles on: ${DBNAME}, ${DB_STAT}, ${DB_AUDIT}");
} else {
  // Update password + roles (safe on first-init; also helpful if you re-run in a dev wipe)
  authDb.updateUser(user, { pwd: pwd, roles: roles });
  print("Updated user '" + user + "' roles/password on: ${DBNAME}, ${DB_STAT}, ${DB_AUDIT}");
}
EOS