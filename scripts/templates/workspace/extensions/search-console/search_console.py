#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path


PLUGIN_ID = "syntella-search-console"
WEBMASTERS_BASE = "https://www.googleapis.com/webmasters/v3"
READONLY_SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
SITE_ALIASES = {
    "asima": "asimaProperty",
    "asima.co.uk": "asimaProperty",
    "wonderful": "wonderfulProperty",
    "wonderful_payments": "wonderfulProperty",
    "wonderful-payments": "wonderfulProperty",
    "wonderful.co.uk": "wonderfulProperty",
}


class SearchConsoleError(RuntimeError):
    pass


def read_request():
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SearchConsoleError(f"Invalid JSON input: {exc}") from exc
    if not isinstance(payload, dict):
        raise SearchConsoleError("Input payload must be a JSON object.")
    return payload


def config_path():
    return Path(os.environ.get("OPENCLAW_CONFIG", os.path.expanduser("~/.openclaw/openclaw.json")))


def load_plugin_entry():
    try:
        with config_path().open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        raise SearchConsoleError(f"Could not read OpenClaw config: {exc}") from exc

    plugins = payload.get("plugins") if isinstance(payload, dict) else {}
    entries = plugins.get("entries") if isinstance(plugins, dict) else {}
    entry = entries.get(PLUGIN_ID) if isinstance(entries, dict) else {}
    if not isinstance(entry, dict):
        entry = {}
    config = entry.get("config")
    if not isinstance(config, dict):
        config = {}
    return {
        "enabled": bool(entry.get("enabled")),
        "config": config,
    }


def configured_sites(config):
    sites = []
    if str(config.get("asimaProperty") or "").strip():
        sites.append({"site": "asima", "property": str(config.get("asimaProperty")).strip()})
    if str(config.get("wonderfulProperty") or "").strip():
        sites.append({"site": "wonderful", "property": str(config.get("wonderfulProperty")).strip()})
    return sites


def ensure_configured(entry):
    config = dict(entry.get("config") or {})
    service_account_raw = str(config.get("serviceAccountJson") or "").strip()
    sites = configured_sites(config)
    return {
        "enabled": bool(entry.get("enabled")),
        "configured": bool(service_account_raw and sites),
        "service_account_raw": service_account_raw,
        "sites": sites,
    }


def normalize_site(site_value, config):
    if site_value is None or str(site_value).strip() == "":
        sites = configured_sites(config)
        if len(sites) == 1:
            return sites[0]
        raise SearchConsoleError("This action needs a site. Use `wonderful` or `asima`.")

    raw = str(site_value).strip()
    alias_key = raw.lower()
    config_key = SITE_ALIASES.get(alias_key)
    if config_key:
        property_value = str(config.get(config_key) or "").strip()
        if not property_value:
            raise SearchConsoleError(f"No Search Console property is configured for `{raw}`.")
        return {"site": "asima" if config_key == "asimaProperty" else "wonderful", "property": property_value}

    if raw.startswith("sc-domain:") or raw.startswith("http://") or raw.startswith("https://"):
        return {"site": "custom", "property": raw}

    raise SearchConsoleError(f"Unknown site `{raw}`. Use `wonderful`, `asima`, or a full Search Console property value.")


def parse_service_account(service_account_raw):
    try:
        service_account = json.loads(service_account_raw)
    except json.JSONDecodeError as exc:
        raise SearchConsoleError(f"Service account JSON is invalid: {exc}") from exc
    if not isinstance(service_account, dict):
        raise SearchConsoleError("Service account JSON must decode to an object.")
    required_keys = ["client_email", "private_key", "token_uri"]
    missing = [key for key in required_keys if not str(service_account.get(key) or "").strip()]
    if missing:
        raise SearchConsoleError(f"Service account JSON is missing: {', '.join(missing)}.")
    return service_account


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign_jwt(unsigned_token, private_key):
    key_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(private_key)
            key_path = handle.name
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
            input=unsigned_token.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as exc:
        raise SearchConsoleError("`openssl` is required to sign Google service-account tokens but is not installed.") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", errors="ignore").strip()
        raise SearchConsoleError(f"Could not sign Google service-account token: {stderr or exc}") from exc
    finally:
        if key_path:
            try:
                os.unlink(key_path)
            except OSError:
                pass
    return base64url(proc.stdout)


def fetch_access_token(service_account):
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {
        "iss": service_account["client_email"],
        "scope": READONLY_SCOPE,
        "aud": service_account["token_uri"],
        "iat": now,
        "exp": now + 3600,
    }
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    encoded_payload = base64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    unsigned = f"{encoded_header}.{encoded_payload}"
    signature = sign_jwt(unsigned, service_account["private_key"])
    assertion = f"{unsigned}.{signature}"
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        service_account["token_uri"],
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    response = request_json(request, include_auth=False)
    token = str(response.get("access_token") or "").strip()
    if not token:
        raise SearchConsoleError("Google token exchange did not return an access token.")
    return token


def request_json(request, include_auth=True, token=None):
    if include_auth and token:
        request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="ignore")
        try:
            payload = json.loads(error_body)
        except json.JSONDecodeError:
            payload = {}
        detail = payload.get("error") if isinstance(payload, dict) else None
        if isinstance(detail, dict):
            message = detail.get("message") or error_body or str(exc)
        else:
            message = error_body or str(exc)
        raise SearchConsoleError(f"Google API request failed ({exc.code}): {message.strip()}") from exc
    except urllib.error.URLError as exc:
        raise SearchConsoleError(f"Could not reach Google API: {exc.reason}") from exc

    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise SearchConsoleError(f"Google API returned invalid JSON: {exc}") from exc


def api_get(url, token):
    request = urllib.request.Request(url, method="GET")
    return request_json(request, token=token)


def api_post(url, payload, token):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    return request_json(request, token=token)


def list_sites(token):
    payload = api_get(f"{WEBMASTERS_BASE}/sites", token)
    entries = payload.get("siteEntry")
    if not isinstance(entries, list):
        return []
    normalized = []
    for item in entries:
        if not isinstance(item, dict):
            continue
        normalized.append(
            {
                "siteUrl": item.get("siteUrl"),
                "permissionLevel": item.get("permissionLevel"),
            }
        )
    return normalized


def api_date_range(days):
    normalized_days = max(1, min(int(days or 28), 365))
    end_date = date.today() - timedelta(days=1)
    start_date = end_date - timedelta(days=normalized_days - 1)
    return {
        "days": normalized_days,
        "startDate": start_date.isoformat(),
        "endDate": end_date.isoformat(),
    }


def search_analytics_query(token, property_value, request_body):
    encoded_site = urllib.parse.quote(property_value, safe="")
    return api_post(f"{WEBMASTERS_BASE}/sites/{encoded_site}/searchAnalytics/query", request_body, token)


def normalize_rows(rows, key_name):
    normalized = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        keys = row.get("keys")
        key_value = keys[0] if isinstance(keys, list) and keys else None
        normalized.append(
            {
                key_name: key_value,
                "clicks": float(row.get("clicks") or 0),
                "impressions": float(row.get("impressions") or 0),
                "ctr": float(row.get("ctr") or 0),
                "position": float(row.get("position") or 0),
            }
        )
    return normalized


def fetch_query_rows(token, property_value, days, search_type, row_limit, start_row=0, filters=None, dimensions=None):
    date_window = api_date_range(days)
    payload = {
        "startDate": date_window["startDate"],
        "endDate": date_window["endDate"],
        "dimensions": dimensions or ["query"],
        "rowLimit": max(1, min(int(row_limit or 250), 25000)),
        "startRow": max(0, int(start_row or 0)),
        "type": search_type or "web",
    }
    if filters:
        payload["dimensionFilterGroups"] = [{"groupType": "and", "filters": filters}]
    if dimensions and "page" in dimensions:
        payload["aggregationType"] = "byPage"
    response = search_analytics_query(token, property_value, payload)
    return {
        "dateWindow": date_window,
        "rows": response.get("rows") or [],
        "responseAggregationType": response.get("responseAggregationType"),
        "metadata": response.get("metadata") if isinstance(response.get("metadata"), dict) else {},
    }


def action_inspect(entry, token, args):
    config = dict(entry.get("config") or {})
    configured = ensure_configured(entry)
    sites = list_sites(token)
    site_index = {
        str(item.get("siteUrl") or ""): item.get("permissionLevel")
        for item in sites
        if str(item.get("siteUrl") or "").strip()
    }
    configured_site_status = []
    for item in configured["sites"]:
        permission_level = site_index.get(item["property"])
        configured_site_status.append(
            {
                "site": item["site"],
                "property": item["property"],
                "accessible": bool(permission_level),
                "permissionLevel": permission_level or None,
            }
        )

    selected = None
    if args.get("site"):
        selected = normalize_site(args.get("site"), config)

    sample = None
    if selected:
        sample_data = fetch_query_rows(
            token,
            selected["property"],
            days=max(3, int(args.get("days") or 7)),
            search_type=args.get("search_type") or "web",
            row_limit=1,
            dimensions=["date"],
        )
        rows = sample_data.get("rows") or []
        sample = {
            "site": selected["site"],
            "property": selected["property"],
            "dateWindow": sample_data["dateWindow"],
            "hasData": bool(rows),
            "rowCount": len(rows),
        }

    return {
        "ok": True,
        "action": "inspect",
        "enabled": configured["enabled"],
        "configured": configured["configured"],
        "configuredSites": configured_site_status,
        "accessibleSites": sites,
        "selectedSiteCheck": sample,
    }


def opportunity_filters(items, min_impressions, position_min, position_max, key_name):
    filtered = []
    for item in items:
        impressions = float(item.get("impressions") or 0)
        position = float(item.get("position") or 0)
        if impressions < min_impressions:
            continue
        if position < position_min or position > position_max:
            continue
        score = impressions * max(position, 1.0) * max(1.0 - float(item.get("ctr") or 0), 0.1)
        enriched = dict(item)
        enriched["opportunityScore"] = round(score, 2)
        enriched[key_name] = item.get(key_name)
        filtered.append(enriched)
    filtered.sort(key=lambda item: (-float(item.get("opportunityScore") or 0), -float(item.get("impressions") or 0)))
    return filtered


def action_query_opportunities(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    limit = max(1, min(int(args.get("limit") or 20), 50))
    min_impressions = float(args.get("min_impressions") or 50)
    position_min = float(args.get("position_min") or 3)
    position_max = float(args.get("position_max") or 20)
    search_type = args.get("search_type") or "web"
    raw = fetch_query_rows(token, site["property"], days, search_type, max(limit * 8, 250))
    normalized = normalize_rows(raw["rows"], "query")
    opportunities = opportunity_filters(normalized, min_impressions, position_min, position_max, "query")[:limit]
    return {
        "ok": True,
        "action": "query_opportunities",
        "site": site["site"],
        "property": site["property"],
        "searchType": search_type,
        "dateWindow": raw["dateWindow"],
        "filters": {
            "minImpressions": min_impressions,
            "positionMin": position_min,
            "positionMax": position_max,
            "limit": limit,
        },
        "rowCount": len(normalized),
        "opportunities": opportunities,
    }


def action_page_opportunities(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    limit = max(1, min(int(args.get("limit") or 10), 25))
    support_limit = max(1, min(int(args.get("supporting_query_limit") or 5), 10))
    min_impressions = float(args.get("min_impressions") or 100)
    position_min = float(args.get("position_min") or 3)
    position_max = float(args.get("position_max") or 20)
    search_type = args.get("search_type") or "web"
    raw = fetch_query_rows(token, site["property"], days, search_type, max(limit * 5, 100), dimensions=["page"])
    pages = normalize_rows(raw["rows"], "page")
    candidates = opportunity_filters(pages, min_impressions, position_min, position_max, "page")[:limit]
    enriched = []
    for page in candidates:
        supporting = fetch_query_rows(
            token,
            site["property"],
            days,
            search_type,
            support_limit,
            filters=[{"dimension": "page", "operator": "equals", "expression": page["page"]}],
            dimensions=["query"],
        )
        page_entry = dict(page)
        page_entry["supportingQueries"] = normalize_rows(supporting["rows"], "query")[:support_limit]
        enriched.append(page_entry)
    return {
        "ok": True,
        "action": "page_opportunities",
        "site": site["site"],
        "property": site["property"],
        "searchType": search_type,
        "dateWindow": raw["dateWindow"],
        "filters": {
            "minImpressions": min_impressions,
            "positionMin": position_min,
            "positionMax": position_max,
            "limit": limit,
            "supportingQueryLimit": support_limit,
        },
        "rowCount": len(pages),
        "opportunities": enriched,
    }


def summarize_page_delta(current, previous, page_url):
    current_clicks = float(current.get("clicks") or 0)
    previous_clicks = float(previous.get("clicks") or 0)
    current_impressions = float(current.get("impressions") or 0)
    previous_impressions = float(previous.get("impressions") or 0)
    current_position = float(current.get("position") or 0)
    previous_position = float(previous.get("position") or 0)
    return {
        "page": page_url,
        "current": current,
        "previous": previous,
        "clickDelta": round(current_clicks - previous_clicks, 2),
        "impressionDelta": round(current_impressions - previous_impressions, 2),
        "positionDelta": round(current_position - previous_position, 2),
    }


def action_declining_pages(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    compare_days = max(1, min(int(args.get("compare_days") or 28), 120))
    limit = max(1, min(int(args.get("limit") or 10), 25))
    min_impressions = float(args.get("min_impressions") or 50)
    search_type = args.get("search_type") or "web"

    current_window = api_date_range(compare_days)
    previous_end = date.fromisoformat(current_window["startDate"]) - timedelta(days=1)
    previous_start = previous_end - timedelta(days=compare_days - 1)

    current_payload = {
        "startDate": current_window["startDate"],
        "endDate": current_window["endDate"],
        "dimensions": ["page"],
        "rowLimit": 500,
        "type": search_type,
        "aggregationType": "byPage",
    }
    previous_payload = {
        "startDate": previous_start.isoformat(),
        "endDate": previous_end.isoformat(),
        "dimensions": ["page"],
        "rowLimit": 500,
        "type": search_type,
        "aggregationType": "byPage",
    }

    current_rows = normalize_rows(
        search_analytics_query(token, site["property"], current_payload).get("rows") or [],
        "page",
    )
    previous_rows = normalize_rows(
        search_analytics_query(token, site["property"], previous_payload).get("rows") or [],
        "page",
    )
    previous_index = {str(item.get("page") or ""): item for item in previous_rows}

    deltas = []
    for current in current_rows:
        page_url = str(current.get("page") or "")
        if not page_url:
            continue
        previous = previous_index.get(page_url)
        if not previous:
            continue
        if float(current.get("impressions") or 0) < min_impressions and float(previous.get("impressions") or 0) < min_impressions:
            continue
        delta = summarize_page_delta(current, previous, page_url)
        if delta["clickDelta"] >= 0 and delta["impressionDelta"] >= 0 and delta["positionDelta"] <= 0:
            continue
        deltas.append(delta)

    deltas.sort(key=lambda item: (item["clickDelta"], item["impressionDelta"], -item["positionDelta"]))
    return {
        "ok": True,
        "action": "declining_pages",
        "site": site["site"],
        "property": site["property"],
        "searchType": search_type,
        "currentWindow": current_window,
        "previousWindow": {
            "days": compare_days,
            "startDate": previous_start.isoformat(),
            "endDate": previous_end.isoformat(),
        },
        "filters": {
            "minImpressions": min_impressions,
            "limit": limit,
        },
        "declines": deltas[:limit],
        "rowCount": len(deltas),
    }


def run_action(args):
    action = str(args.get("action") or "inspect").strip() or "inspect"
    entry = load_plugin_entry()
    configured = ensure_configured(entry)

    if action == "inspect":
        if not configured["enabled"] or not configured["configured"]:
            return {
                "ok": True,
                "action": "inspect",
                "enabled": configured["enabled"],
                "configured": configured["configured"],
                "configuredSites": configured["sites"],
                "accessibleSites": [],
            }
        service_account = parse_service_account(configured["service_account_raw"])
        token = fetch_access_token(service_account)
        return action_inspect(entry, token, args)

    if not configured["enabled"]:
        raise SearchConsoleError("Google Search Console integration is disabled for this workspace.")
    if not configured["configured"]:
        raise SearchConsoleError("Google Search Console integration is missing a property or service-account JSON.")

    service_account = parse_service_account(configured["service_account_raw"])
    token = fetch_access_token(service_account)

    if action == "query_opportunities":
        return action_query_opportunities(entry, token, args)
    if action == "page_opportunities":
        return action_page_opportunities(entry, token, args)
    if action == "declining_pages":
        return action_declining_pages(entry, token, args)

    raise SearchConsoleError(
        "Unknown action. Use `inspect`, `query_opportunities`, `page_opportunities`, or `declining_pages`."
    )


def main():
    try:
        args = read_request()
        result = run_action(args)
    except SearchConsoleError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:
        result = {"ok": False, "error": f"Unexpected Search Console error: {exc}"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
