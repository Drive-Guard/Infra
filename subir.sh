#!/usr/bin/env bash
# DriveGuard: sobe o projeto inteiro (Linux e WSL). Antes: no Learner Lab,
# Start Lab e copie o bloco de AWS Details > AWS CLI. Ver scripts/subir.sh.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/subir.sh" "$@"
