#!/usr/bin/env bash
set -euo pipefail

# Creates the UniFi DB user on first Mongo init.
# This runs only when /data/db is EMPTY.
#
# Expected env vars:
#   MONGO_USER, MONGO_PASS
#   MONGO_DBNAME, MONGO_DB_STAT, MONGO_DB_AUDIT
#   MONGO_AUTHSOURCE
#   MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD

mongosh --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin <<EOS
const AUTH_DB = "${MONGO_AUTHSOURCE:-admin}";
const USER    = "${MONGO_USER}";
const PASS    = "${MONGO_PASS}";
const DBNAME  = "${MONGO_DBNAME}";
const DBSTAT  = "${MONGO_DB_STAT:-unifi_stat}";
const DBAUDIT = "${MONGO_DB_AUDIT:-unifi_audit}";

const adminDb = db.getSiblingDB(AUTH_DB);

if (adminDb.getUser(USER) == null) {
  adminDb.createUser({
    user: USER,
    pwd:  PASS,
    roles: [
      { role: "dbOwner", db: DBNAME },
      { role: "dbOwner", db: DBSTAT },
      { role: "dbOwner", db: DBAUDIT }
    ]
  });
  print(`Created user '${USER}' with dbOwner on '${DBNAME}', '${DBSTAT}', '${DBAUDIT}'.`);
} else {
  print(`User '${USER}' already exists; skipping.`);
}
EOS
