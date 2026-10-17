#!/usr/bin/env bash
# DriveGuard: APAGA tudo o que o projeto criou na conta AWS (pede confirmação).
# O bucket do state (driveguard-tfstate-<conta>) fica, para o próximo subir.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/subir.sh" --desligar "$@"
