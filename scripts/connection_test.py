#!/usr/bin/env python3
"""
ACR Connection Test Script

Verifies connectivity to an Azure Container Registry by:
1. Authenticating with DefaultAzureCredential (Azure CLI locally, managed identity in CI/CD)
2. Listing repositories in the registry
3. Listing tags for each repository (up to 5)
4. Printing clear success or failure output

Usage:
    # Set the login server (from terraform output or manually)
    export ACR_LOGIN_SERVER="myregistry.azurecr.io"

    # Run with Azure CLI credentials
    az login
    python scripts/connection_test.py

    # Or run with managed identity in CI/CD (no az login needed)
    python scripts/connection_test.py

Requirements:
    pip install azure-containerregistry azure-identity
"""

import os
import sys
import time

from azure.containerregistry import ContainerRegistryClient
from azure.identity import DefaultAzureCredential


def main():
    login_server = os.environ.get("ACR_LOGIN_SERVER")
    if not login_server:
        print("ERROR: ACR_LOGIN_SERVER environment variable is not set.")
        print("Set it to your registry's login server, e.g.:")
        print("  export ACR_LOGIN_SERVER=\"myregistry.azurecr.io\"")
        sys.exit(1)

    endpoint = f"https://{login_server}"
    print(f"Connecting to: {endpoint}")
    print("-" * 50)

    try:
        credential = DefaultAzureCredential()
        client = ContainerRegistryClient(endpoint, credential)
    except Exception as e:
        print(f"FAIL: Authentication error — {e}")
        print()
        print("Ensure you are logged in:")
        print("  az login")
        print("Or that a managed identity with AcrPull role is available.")
        sys.exit(1)

    # List repositories
    start = time.time()
    try:
        repos = list(client.list_repository_names())
        elapsed = time.time() - start
        print(f"OK: Listed {len(repos)} repositories ({elapsed:.2f}s)")
    except Exception as e:
        print(f"FAIL: Could not list repositories — {e}")
        sys.exit(1)

    if not repos:
        print("INFO: Registry is empty (no repositories found).")
        print()
        print("SUCCESS: Connection to ACR is working.")
        sys.exit(0)

    # List tags for up to 5 repositories
    for repo_name in repos[:5]:
        try:
            props = client.get_repository_properties(repo_name)
            manifest_count = props.manifest_count
            print(f"  {repo_name}: {manifest_count} manifest(s)")
        except Exception as e:
            print(f"  {repo_name}: WARN — could not read properties ({e})")

    if len(repos) > 5:
        print(f"  ... and {len(repos) - 5} more repositories")

    print()
    print("SUCCESS: Connection to ACR is working.")


if __name__ == "__main__":
    main()
