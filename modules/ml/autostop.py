#!/usr/bin/env python3
"""
Desliga o notebook SageMaker após N minutos ociosos.

Roda de 5 em 5 minutos via cron. Considera "ocioso" o notebook sem nenhuma
sessão aberta e sem kernel em execução. Sem isso, uma instância esquecida
ligada consome o budget de US$100 do Learner Lab em poucos dias
(ml.t3.medium ~ US$0,05/h = US$36/mês rodando direto).

O limite em minutos vem da variável de ambiente IDLE_LIMIT_MINUTES.
"""

import json
import os
import subprocess
import urllib.request

IDLE_LIMIT_MINUTES = int(os.environ.get("IDLE_LIMIT_MINUTES", "60"))
INTERVALO_CRON_MINUTOS = 5
CONTADOR = "/tmp/driveguard_idle_minutes"
METADATA = "/opt/ml/metadata/resource-metadata.json"


def _get(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.load(resp)


def esta_ocioso() -> bool:
    try:
        sessoes = _get("http://localhost:8888/api/sessions")
        kernels = _get("http://localhost:8888/api/kernels")
    except Exception:
        # Jupyter fora do ar: não é sinal de ociosidade, não conta.
        return False

    if sessoes:
        return False
    return not any(k.get("execution_state") == "busy" for k in kernels)


def ler_contador() -> int:
    try:
        with open(CONTADOR) as fh:
            return int(fh.read().strip())
    except Exception:
        return 0


def gravar_contador(valor: int) -> None:
    with open(CONTADOR, "w") as fh:
        fh.write(str(valor))


def main() -> None:
    if not esta_ocioso():
        gravar_contador(0)
        return

    minutos = ler_contador() + INTERVALO_CRON_MINUTOS
    gravar_contador(minutos)

    if minutos < IDLE_LIMIT_MINUTES:
        return

    with open(METADATA) as fh:
        nome = json.load(fh)["ResourceName"]

    print(f"Notebook {nome} ocioso ha {minutos} min: desligando.")
    subprocess.run(
        ["aws", "sagemaker", "stop-notebook-instance", "--notebook-instance-name", nome],
        check=False,
    )


if __name__ == "__main__":
    main()
