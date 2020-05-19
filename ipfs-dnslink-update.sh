#!/bin/bash

set -e

die() {
  echo "ERROR: $*" 1>&2
  exit 2
}

[ ! -e "$HOME/.dnslink-cred" ] && die "DNSLink update credentials not found in $HOME/.dnslink-cred"
. "$HOME/.dnslink-cred"

CF_API="https://api.cloudflare.com/client/v4"
CF_CRED=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
CF_SEARCH="&status=active&page=1&per_page=20&order=name&direction=desc&match=all"

PDNS_CRED=(-H "X-API-Key: $PDNS_KEY")

getjson() {
  jqf="$1"
  shift
  res=$(curl --silent "$@")
  if ! echo "$res" | jq "." > /dev/null; then
    echo "$res" 1>&2
    die "Not a JSON result"
  fi
  if echo "$res" | jq "$SUCCESS_VAR" | grep -o "$FAIL_PATTERN" > /dev/null; then
    echo "$res" 1>&2
    echo "Request not successfull!" 1>&2
    exit 2
  fi
  PRE_RES=$(echo "$res" | jq -c "$jqf")
  [ -z "$DONT_STRIP" ] && PRE_RES=$(echo "$PRE_RES" | sed 's|"||g' | sed -r "s|\[\|\]||g")
  echo "$PRE_RES"
}

if [ "$1" == "edit" ]; then
  [ ! -e "$HOME/.selected_editor" ] && select-editor
  . "$HOME/.selected_editor"
  "$SELECTED_EDITOR" "$HOME/.dnslink-cred"
  exit $?
fi

PROVIDER="$1"
DOMAIN="$2"
ZONE=$(echo "$DOMAIN" | sed -r "s|.*\.*.*\.(.*\..*)|\1|g")
DNSLINK="$3"

echo "Updating DNSLink of $DOMAIN (in $ZONE) to '$DNSLINK' using $PROVIDER..."

case "$PROVIDER" in
  powerdns|pdns)
    if [ -z "$PDNS_KEY" ] || [ -z "$PDNS_API" ]; then
      die "PowerDNS API Url (PDNS_API - ex. http://your-powerdns-server.com:8080/api/v1/servers/localhost) or PowerDNS API Key (PDNS_KEY) missing!"
    fi
    SUCCESS_VAR=".error"
    FAIL_PATTERN="^\""
    DONT_STRIP=1
    URL="$PDNS_API/zones/$ZONE."
    RRSETS=$(getjson ".rrsets[] | [.name, .type, .ttl , .records]" -X GET "$URL" "${PDNS_CRED[@]}")
    RRSETS=$(echo "$RRSETS" | grep '^\["'"$DOMAIN."'","TXT"' || echo "")
    RRSET_DNSLINK=$(echo "$RRSETS" | grep '\"dnslink=' || echo "")
    if [ -z "$RRSETS" ]; then
      echo "Did not find any TXT RRSet for $DOMAIN."
      echo "Create TXT RRSet for $DOMAIN with '\"dnslink=$DNSLINK\"'..."
      getjson "" -X PATCH "$URL" "${PDNS_CRED[@]}" --data '{"rrsets": [{"name": "'"$DOMAIN."'", "type": "TXT", "ttl": 300, "changetype": "REPLACE", "records": [{"content": "'"\\\"dnslink=$DNSLINK\\\""'", "disabled": false}]}]}' > /dev/null
    else
      if [ -z "$RRSET_DNSLINK" ]; then
        echo "Found TXT RRSet without dnslink for $DOMAIN.: $RRSETS"
        RECORDS=$(echo "$RRSETS" | jq -c ".[3]" | sed -r "s|\\]$|,{\"content\": \"\\\\\"dnslink=$DNSLINK\\\\\"\", \"disabled\": false}\\]|g")
        getjson "" -X PATCH "$URL" "${PDNS_CRED[@]}" --data '{"rrsets": [{"name": "'"$DOMAIN."'", "type": "TXT", "ttl": '"$(echo "$RRSETS" | jq -c ".[2]")"', "changetype": "REPLACE", "records": '"$RECORDS"'}]}' > /dev/null
      else
        echo "Found TXT RRSet with dnslink for $DOMAIN.: $RRSET_DNSLINK"
        RECORDS=$(echo "$RRSET_DNSLINK" | jq -c ".[3]" | sed -r "s|dnslink=.*(\\\\\")|dnslink=$DNSLINK\1|g")
        getjson "" -X PATCH "$URL" "${PDNS_CRED[@]}" --data '{"rrsets": [{"name": "'"$DOMAIN."'", "type": "TXT", "ttl": '"$(echo "$RRSET_DNSLINK" | jq -c ".[2]")"', "changetype": "REPLACE", "records": '"$RECORDS"'}]}' > /dev/null
      fi
    fi
    ;;
  cloudflare|cf)
    if [ -z "$CF_KEY" ] || [ -z "$CF_EMAIL" ]; then
      die "Cloudflare API Key (CF_KEY) or Cloudflare E-Mail (CF_EMAIL) missing!"
    fi
    SUCCESS_VAR=".success"
    FAIL_PATTERN="false"
    echo "Retrieving zone id..."
    ZONEID=$(getjson ".result[0].id" -X GET "$CF_API/zones?name=$ZONE$CF_SEARCH" "${CF_CRED[@]}")
    echo "Zone ID: $ZONEID"
    DOMAINS=$(getjson ".result[] | [.id, .type]" -X GET "$CF_API/zones/$ZONEID/dns_records?name=$DOMAIN$CF_SEARCH" "${CF_CRED[@]}")
    TXTs=$(echo "$DOMAINS" | grep ",TXT$" || echo "")
    if [ -z "$TXTs" ]; then
      echo "No TXT for $DOMAIN found"
      echo "Creating TXT $DOMAIN 'dnslink=$DNSLINK'..."
      getjson ".result.id" -X POST "$CF_API/zones/$ZONEID/dns_records" "${CF_CRED[@]}" --data '{"type":"TXT","name":"'"$DOMAIN"'","content":"'"dnslink=$DNSLINK"'"}'
    else
      DOMAINIDs=$(echo "$TXTs" | sed "s|,TXT||g")
      echo "Found TXTs for $DOMAIN:" $DOMAINIDs
      echo "Searching for dnslink="
      didfind=false
      for ID in $DOMAINIDs; do
        RES=$(getjson ".result.content" -X GET "$CF_API/zones/$ZONEID/dns_records/$ID" "${CF_CRED[@]}")
        if echo "$RES" | grep "^dnslink=" > /dev/null; then
          echo "Update $ID from '$RES' to 'dnslink=$DNSLINK'..."
          getjson ".result.id" -X PUT "$CF_API/zones/$ZONEID/dns_records/$ID" "${CF_CRED[@]}" --data '{"type":"TXT","name":"'"$DOMAIN"'","content":"'"dnslink=$DNSLINK"'"}'
          didfind=true
        fi
      done
      if ! $didfind; then
        echo "No DNSLINK TXT for $DOMAIN found"
        echo "Creating TXT $DOMAIN 'dnslink=$DNSLINK'..."
        getjson ".result.id" -X POST "$CF_API/zones/$ZONEID/dns_records" "${CF_CRED[@]}" --data '{"type":"TXT","name":"'"$DOMAIN"'","content":"'"dnslink=$DNSLINK"'"}'
      fi
    fi
    ;;
  *)
    die "Unknown provider $PROVIDER!"
    ;;
esac

