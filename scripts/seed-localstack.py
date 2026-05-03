#!/usr/bin/env python3
"""
Generic LocalStack secret seeder — creates or updates a Secrets Manager secret
from a .env file.

Can be used two ways:

  1. As a LocalStack init hook (mounted at
     /etc/localstack/init/ready.d/01-seed-secrets.py).  LocalStack executes it
     after all services are ready.  Default SEED_MODE=create skips the write if
     the secret already exists so PERSISTENCE=1 restarts do not overwrite live
     secrets.

  2. Called directly from deploy.sh (or any operator script) with
     SEED_MODE=upsert to create-or-update the secret on every deploy so that
     changes to the env file are picked up automatically.

Environment variables:
  SEED_SECRET_NAME   — required; Secrets Manager secret name
                       (e.g. cdp/authentication/dev/env)
  SEED_ENV_FILE      — required; path to a .env file whose key=value pairs
                       become the JSON secret body
  SEED_MODE          — optional; "create" (default) skips if secret exists;
                       "upsert" creates or updates
  AWS_DEFAULT_REGION — defaults to us-east-1
  AWS_ENDPOINT_URL   — defaults to http://localhost:4566
"""

from __future__ import annotations

import json
import os
import sys

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")


def _client() -> boto3.client:
    return boto3.client(
        "secretsmanager",
        endpoint_url=ENDPOINT,
        region_name=REGION,
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


def _secret_exists(client: boto3.client, secret_name: str) -> bool:
    try:
        client.describe_secret(SecretId=secret_name)
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ResourceNotFoundException":
            return False
        raise


def _parse_env_file(path: str) -> dict[str, str]:
    """Parse a .env file into a dict, skipping blank lines and comments."""
    bundle: dict[str, str] = {}
    with open(path) as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            # Strip optional surrounding quotes (single or double)
            value = value.strip().strip("\"'")
            if key:
                bundle[key] = value
    return bundle


def main() -> None:
    secret_name = os.environ.get("SEED_SECRET_NAME", "").strip()
    env_file = os.environ.get("SEED_ENV_FILE", "").strip()

    if not secret_name:
        print(
            "ERROR: SEED_SECRET_NAME is not set. "
            "Set it via docker-compose environment.",
            file=sys.stderr,
        )
        sys.exit(1)

    if not env_file:
        print(
            "ERROR: SEED_ENV_FILE is not set. "
            "Set it via docker-compose environment and mount the file.",
            file=sys.stderr,
        )
        sys.exit(1)

    if not os.path.isfile(env_file):
        print(
            f"ERROR: SEED_ENV_FILE '{env_file}' does not exist inside the container. "
            "Mount your .env file at that path.",
            file=sys.stderr,
        )
        sys.exit(1)

    client = _client()
    mode = os.environ.get("SEED_MODE", "create").strip().lower()

    if _secret_exists(client, secret_name):
        if mode == "upsert":
            bundle = _parse_env_file(env_file)
            client.put_secret_value(
                SecretId=secret_name,
                SecretString=json.dumps(bundle),
            )
            print(
                f"[seed-localstack] Updated '{secret_name}' with {len(bundle)} keys."
            )
        else:
            print(
                f"[seed-localstack] Secret '{secret_name}' already exists "
                "— skipping seed (PERSISTENCE mode)."
            )
        return

    bundle = _parse_env_file(env_file)
    if not bundle:
        print(
            f"WARNING: '{env_file}' contained no key=value pairs — "
            "creating an empty secret.",
            file=sys.stderr,
        )

    client.create_secret(
        Name=secret_name,
        SecretString=json.dumps(bundle),
        Description=f"Seeded by seed-localstack.py from {env_file}",
    )
    print(
        f"[seed-localstack] Created '{secret_name}' with {len(bundle)} keys."
    )


if __name__ == "__main__":
    main()
