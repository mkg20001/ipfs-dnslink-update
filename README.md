# ipfs-dnslink-update

A bash script to update DNSLink TXT records

## Requirements

 - A domain
 - jq, curl, coreutils

## Usage

```sh
# Update DNSLink for some.domain.com to /ipfs/Qmfoobar using Cloudflare DNS
$ ipfs-dnslink-update cf some.domain.com /ipfs/Qmfoobar
# Edit the credential config
$ ipfs-dnslink-update edit
```

## Supported providers

 - PowerDNS (alias: powerdns, pdns)
 - Cloudflare DNS (alias: cloudflare, cf)

