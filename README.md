This is a script to export a Synology-managed DDNS certificate to a directory for use by Docker-based reverse proxies or other TLS-enabled applications. DSM remains responsible for certificate issuance and renewal. The script automatically discovers the configured Synology DDNS hostname, selects the appropriate matching certificate by case-insensitive Common Name, and exports its PEM files plus an RSA compatibility keypair. 

**Note:** Caddy is currently the only supported proxy reload handler. The script was written with other handlers in mind if there is interest. Pull Requests are welcome.

## Requirements

- Synology DSM with a configured built-in Synology DDNS record and matching certificate. The certificate archive must properly contain `RSA-cert.pem`, `RSA-chain.pem` and `RSA-privkey.pem`
- Root execution (including DSM Task Scheduler)
- Bash access with the ability to run standard DSM utilities
- Docker is required only for the `--reload` option to automatically reload the certificate

### Tested/Development environment

| Component | Version |
|:---|:---|
| NAS | DS1019+ (x86_64) |
| DSM | 7.4.1-90080 Update 2 |
| Bash | 4.4.23 |
| jq | 1.5 |
| OpenSSL | 1.1.1w |
| Docker | 24.0.2 |
| Caddy | 2.11.4 (`caddy:2-alpine`) |

These are observed reference versions as per development, testing and personal use by the author. This is not a list of minimum supported versions. No supplemental utility installation should be necessary.

## Installation and usage

Copy `exportSynoCert.sh` to a trusted directory on the NAS and make it executable:

```bash
chmod 755 exportSynoCert.sh
```

| Option | Behavior |
|---|---|
| No options or `-h` | Show help |
| `-s` | Display certificate summary |
| `-i` | Print certificate ID only |
| `-o OUTPUT_DIR` | Export PEM files and generate compatibility keypair |
| `--reload` | Detect, validate and reload the matching proxy; requires `-o` |

```bash
./exportSynoCert.sh -s
./exportSynoCert.sh -i
./exportSynoCert.sh -o /volume1/docker/caddy/certs
./exportSynoCert.sh -o /volume1/docker/caddy/certs --reload
```

See [Caddy on Synology](docs/caddy-synology.md) for a full deployment example.

## How it works

The local DSM APIs `SYNO.Core.DDNS.Record` and `SYNO.Core.Certificate.CRT` are called with `synowebapi`. The script selects the record whose provider is `Synology`, then requires a unique certificate Common Name match. Certificate archives are read from:

```/usr/syno/etc/certificate/_archive/<ID>```

The export copies source PEM files, generates `fullchain.pem` from the RSA certificate and intermediate chain, and creates `privkey.pem` from the RSA private key. The script validates certificate material, rejects expired certificates, warns within 14 days of expiration, compares existing files, and stages changed files on the destination filesystem. Chain verification checks linkage using the supplied chain as trust material, not independent public CA trust. Individual renames are atomic; the entire set is not a single atomic transaction.

A global atomic directory lock at `/run/exportSynoCert.lock.d` serializes exports without requiring a supplemental utility.

With `--reload`, the script inspects running Docker containers for the output directory or an ancestor mount and probes supported proxy executables. It requires exactly one matching candidate. Caddy uses `/etc/caddy/Caddyfile`, validates its configuration, and force-reloads it even if the export is unchanged. Without `--reload`, Docker is not needed and no proxy commands are issued.
