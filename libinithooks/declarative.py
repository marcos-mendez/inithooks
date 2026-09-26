# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Declarative instance description reader

The declarative file describes what an instance should be. It is
translated into the inithooks conf file (the preseed) that the firstboot
hooks already read, so no hook needs to know that it exists.

The parser is deliberately kept in a single function (load) so that the
file format can be changed without touching anything else here.
"""

import ipaddress
import os
import re
import secrets as secrets_module
import shlex
import subprocess
from typing import Any

import yaml

try:
    from libinithooks.dialog_wrapper import validate_domain
except Exception:
    # dialog_wrapper needs python3-dialog and a writable dialog log; the
    # reader must keep working without them
    validate_domain = None

DECL_DEFAULT = "/etc/inithooks.yaml"
CONF_DEFAULT = "/etc/inithooks.conf"
LXC_MARKER = "/var/lib/turnkey-info/inithooks.service/lxc"

SCHEMA_VERSION = 1
GENERATED_BYTES = 12
MASK = "[masked]"

TOP_LEVEL_KEYS = (
    "version",
    "instance",
    "network",
    "tls",
    "secrets",
    "app",
    "hub",
    "security",
    "first_login_wizard",
    "preseed",
)
SECRET_VARS = {
    "root_password": "ROOT_PASS",
    "db_password": "DB_PASS",
    "app_password": "APP_PASS",
}
MASKED_VARS = tuple(SECRET_VARS.values()) + ("HUB_APIKEY",)
KEYWORDS = ("SKIP", "FORCE", "TRUE", "FALSE")
WIZARD_ONLY_GENERATE = ("root_password", "app_password")
SECRET_BACKENDS = ("file", "generate")
MANAGED_BY = ("host", "file")
IPV4_METHODS = ("static", "dhcp", "manual", "none")
IPV6_METHODS = ("static", "dhcp", "auto", "manual", "none")

_LABEL_RE = re.compile(r"^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class DeclarativeError(Exception):
    pass


def load(path: str) -> dict:
    """Parse the declarative file, raise DeclarativeError if it cannot be"""
    try:
        with open(path) as fob:
            doc = yaml.safe_load(fob)
    except OSError as e:
        raise DeclarativeError(f"{path}: {e}")
    except yaml.YAMLError as e:
        raise DeclarativeError(f"{path}: not valid YAML: {e}")

    if doc is None:
        raise DeclarativeError(f"{path}: file is empty")
    if not isinstance(doc, dict):
        raise DeclarativeError(f"{path}: top level must be a mapping")
    return doc


def validate(doc: dict) -> list[str]:
    """Return a list of error messages, empty when the document is valid"""
    errors: list[str] = []

    if doc.get("version") != SCHEMA_VERSION:
        errors.append(f"version: must be {SCHEMA_VERSION}")
    for key in doc:
        if key not in TOP_LEVEL_KEYS:
            errors.append(f"{key}: unknown top level key")

    errors.extend(_validate_instance(doc.get("instance")))
    errors.extend(_validate_secrets(doc))
    errors.extend(_validate_app(doc.get("app")))
    errors.extend(_validate_hub(doc.get("hub")))
    errors.extend(_validate_security(doc.get("security")))
    errors.extend(_validate_wizard(doc.get("first_login_wizard")))
    errors.extend(_validate_network(doc.get("network")))
    errors.extend(_validate_tls(doc.get("tls")))
    errors.extend(_validate_preseed(doc.get("preseed")))
    return errors


def resolve_secrets(doc: dict) -> dict[str, str]:
    """Read or generate every declared secret, keyed by variable name"""
    declared = doc.get("secrets") or {}
    resolved = {}
    for name, var in SECRET_VARS.items():
        spec = declared.get(name)
        if isinstance(spec, dict):
            resolved[var] = _resolve_secret(spec)

    api_key = (doc.get("hub") or {}).get("api_key")
    if isinstance(api_key, dict):
        resolved["HUB_APIKEY"] = _resolve_secret(api_key)
    return resolved


def _resolve_secret(spec: dict) -> str:
    if spec.get("generate"):
        return secrets_module.token_urlsafe(GENERATED_BYTES)
    return _read_secret_file(str(spec["file"]))


def render_env(doc: dict, secrets: dict[str, str]) -> str:
    """Render the document and the resolved secrets as a shell conf file"""
    env: dict[str, str] = {}

    instance = doc.get("instance") or {}
    _set(env, "HOSTNAME", instance.get("hostname"))
    _set(env, "FQDN", instance.get("fqdn"))

    for var in SECRET_VARS.values():
        _set(env, var, secrets.get(var))

    app = doc.get("app") or {}
    _set(env, "APP_EMAIL", app.get("email"))
    _set(env, "APP_DOMAIN", app.get("domain"))
    for key, value in (app.get("options") or {}).items():
        _set(env, f"APP_{str(key).upper()}", value)

    hub = doc.get("hub") or {}
    api_key = hub.get("api_key")
    if isinstance(api_key, dict):
        api_key = secrets.get("HUB_APIKEY")
    _set(env, "HUB_APIKEY", _keyword(api_key))

    security = doc.get("security") or {}
    _set(env, "SEC_ALERTS", _keyword(security.get("alerts")))
    _set(env, "SEC_UPDATES", _keyword(security.get("updates")))

    if doc.get("first_login_wizard"):
        env["AUTO_RUN"] = "TRUE"

    env.update(_network_env(doc.get("network")))

    for key, value in (doc.get("preseed") or {}).items():
        _set(env, str(key), value)

    lines = [
        f"export {key}={shlex.quote(value)}" for key, value in env.items()
    ]
    return "".join(f"{line}\n" for line in lines)


def mask(text: str) -> str:
    """Replace every secret value in a rendered conf with a placeholder"""
    masked = []
    for line in text.splitlines():
        key, _, value = line[len("export "):].partition("=")
        if key in MASKED_VARS and value not in KEYWORDS:
            line = f"export {key}={MASK}"
        masked.append(line)
    return "".join(f"{line}\n" for line in masked)


def write_conf(text: str, path: str) -> None:
    """Write the rendered conf, readable by root only"""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fob:
        fob.write(text)
    os.chmod(path, 0o600)


def default_managed_by() -> str:
    """Containers get their addresses from the host, other builds do not"""
    if os.path.exists(LXC_MARKER):
        return "host"
    try:
        out = subprocess.run(
            ["turnkey-version", "-n"], capture_output=True, text=True
        )
    except OSError:
        return "file"
    if out.stdout.strip() == "lxc":
        return "host"
    return "file"


def check_network(doc: dict) -> list[str]:
    """Compare declared addresses with the live ones (host managed only)

    A mismatch must be visible but must not stop the run, so this returns
    messages instead of raising.
    """
    network = doc.get("network") or {}
    if _managed_by(network) != "host":
        return []

    messages = []
    for name, iface in (network.get("interfaces") or {}).items():
        declared = ((iface or {}).get("ipv6") or {}).get("address")
        if not declared:
            continue
        wanted = str(declared).split("/")[0]
        live = _live_ipv6(str(name))
        if wanted not in live:
            found = ", ".join(live) or "none"
            messages.append(
                f"network.interfaces.{name}: declared address {declared}"
                f" is not configured on the interface (found: {found})"
            )
    return messages


def unsupported(doc: dict) -> list[str]:
    """Return the declared features this version does not act on"""
    acme = (doc.get("tls") or {}).get("acme") or {}
    if acme.get("enabled"):
        return [
            "tls.acme: certificates are not requested by this version;"
            " use confconsole to get one"
        ]
    return []


def _live_ipv6(iface: str) -> list[str]:
    try:
        out = subprocess.run(
            ["ip", "-6", "addr", "show", iface, "scope", "global"],
            capture_output=True,
            text=True,
        )
    except OSError:
        return []
    addresses = []
    for line in out.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] == "inet6":
            addresses.append(fields[1].split("/")[0])
    return addresses


def _set(env: dict[str, str], key: str, value: Any) -> None:
    if value is None:
        return
    if isinstance(value, bool):
        value = "TRUE" if value else "FALSE"
    env[key] = str(value)


def _keyword(value: Any) -> Any:
    """SKIP, FORCE and friends are compared upper case by the hooks"""
    if isinstance(value, str) and value.lower() in ("skip", "force"):
        return value.upper()
    return value


def _managed_by(network: dict) -> str:
    return str(network.get("managed_by") or default_managed_by())


def _network_env(network: Any) -> dict[str, str]:
    """Map the network section onto the IP_* variables 01ipconfig reads

    Only the file managed case exports anything: when the host owns the
    interface configuration there is nothing for 01ipconfig to write.
    """
    env: dict[str, str] = {}
    if not isinstance(network, dict) or _managed_by(network) != "file":
        return env

    interfaces = network.get("interfaces") or {}
    for iface in interfaces.values():
        ipv4 = (iface or {}).get("ipv4") or {}
        method = str(ipv4.get("method") or "none")
        if method == "none":
            continue
        env["IP_CONFIG"] = method
        if method != "static":
            continue
        address = ipaddress.ip_interface(str(ipv4["address"]))
        env["IP_ADDRESS"] = str(address.ip)
        env["IP_NETMASK"] = str(address.netmask)
        _set(env, "IP_GW", ipv4.get("gateway"))

    nameservers = [
        str(server)
        for server in (network.get("nameservers") or [])
        if _is_ipv4(str(server))
    ]
    for index, server in enumerate(nameservers[:2], start=1):
        env[f"IP_DNS{index}"] = server
    return env


def _is_ipv4(value: str) -> bool:
    try:
        return ipaddress.ip_address(value).version == 4
    except ValueError:
        return False


def _read_secret_file(path: str) -> str:
    error = _secret_file_error(path)
    if error:
        raise DeclarativeError(error)
    with open(path, "rb") as fob:
        data = fob.read()
    if data.endswith(b"\n"):
        data = data[:-1]
    return data.decode()


def _secret_file_error(path: str) -> str | None:
    if not os.path.isfile(path):
        return f"{path}: secret file not found"
    stat = os.stat(path)
    if stat.st_mode & 0o077:
        return f"{path}: secret file mode must be 0600 or stricter"
    if stat.st_uid not in (0, os.geteuid()):
        return f"{path}: secret file must be owned by root"
    return None


def _domain_error(key: str, value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return f"{key}: must be a domain name"
    if validate_domain is not None:
        domain, _scheme, message = validate_domain(value)
        if domain is None or message is not None:
            return f"{key}: {message}"
        return None
    host = value.strip().rstrip(".")
    labels = host.split(".")
    if len(host) > 253 or not all(_LABEL_RE.match(label) for label in labels):
        return f'{key}: domain "{value}" is invalid'
    return None


def _mapping_error(key: str, value: Any) -> str | None:
    if value is not None and not isinstance(value, dict):
        return f"{key}: must be a mapping"
    return None


def _validate_instance(instance: Any) -> list[str]:
    error = _mapping_error("instance", instance)
    if error or not instance:
        return [error] if error else []

    errors = []
    for key in instance:
        if key not in ("hostname", "fqdn"):
            errors.append(f"instance.{key}: unknown key")
    for key in ("hostname", "fqdn"):
        if key in instance:
            error = _domain_error(f"instance.{key}", instance[key])
            if error:
                errors.append(error)
    return errors


def _validate_secrets(doc: dict) -> list[str]:
    declared = doc.get("secrets")
    error = _mapping_error("secrets", declared)
    if error or not declared:
        return [error] if error else []

    wizard = bool(doc.get("first_login_wizard"))
    errors = []
    for name, spec in declared.items():
        key = f"secrets.{name}"
        if name not in SECRET_VARS:
            errors.append(f"{key}: unknown secret")
            continue
        errors.extend(_validate_secret(key, spec))
        if not isinstance(spec, dict):
            continue
        if (
            spec.get("generate")
            and name in WIZARD_ONLY_GENERATE
            and not wizard
        ):
            errors.append(
                f"{key}: generate needs first_login_wizard, otherwise"
                " nobody can log in with the generated value"
            )
    return errors


def _validate_secret(key: str, spec: Any) -> list[str]:
    if not isinstance(spec, dict):
        return [f"{key}: must be a mapping"]

    backends = [name for name in SECRET_BACKENDS if name in spec]
    unknown = [name for name in spec if name not in SECRET_BACKENDS]
    errors = [f"{key}.{name}: unknown secret backend" for name in unknown]
    if len(backends) != 1:
        errors.append(
            f"{key}: exactly one of {', '.join(SECRET_BACKENDS)} is required"
        )
        return errors
    if "file" in spec:
        error = _secret_file_error(str(spec["file"]))
        if error:
            errors.append(f"{key}: {error}")
    return errors


def _validate_app(app: Any) -> list[str]:
    error = _mapping_error("app", app)
    if error or not app:
        return [error] if error else []

    errors = []
    for key in app:
        if key not in ("email", "domain", "options"):
            errors.append(f"app.{key}: unknown key")
    if "email" in app and not _EMAIL_RE.match(str(app["email"])):
        errors.append("app.email: must be an email address")
    if "domain" in app:
        error = _domain_error("app.domain", app["domain"])
        if error:
            errors.append(error)

    options = app.get("options")
    error = _mapping_error("app.options", options)
    if error:
        return errors + [error]
    for key in options or {}:
        if not _NAME_RE.match(str(key)):
            errors.append(f"app.options.{key}: not a valid variable name")
    return errors


def _validate_hub(hub: Any) -> list[str]:
    error = _mapping_error("hub", hub)
    if error or not hub:
        return [error] if error else []

    errors = []
    for key in hub:
        if key != "api_key":
            errors.append(f"hub.{key}: unknown key")
    api_key = hub.get("api_key")
    if isinstance(api_key, dict):
        errors.extend(_validate_secret("hub.api_key", api_key))
    elif api_key is not None and str(api_key).lower() != "skip":
        errors.append("hub.api_key: must be 'skip' or a secret mapping")
    return errors


def _validate_security(security: Any) -> list[str]:
    error = _mapping_error("security", security)
    if error or not security:
        return [error] if error else []

    errors = []
    for key in security:
        if key not in ("alerts", "updates"):
            errors.append(f"security.{key}: unknown key")

    alerts = security.get("alerts")
    if alerts is not None and str(alerts).lower() != "skip":
        if not _EMAIL_RE.match(str(alerts)):
            errors.append(
                "security.alerts: must be 'skip' or an email address"
            )

    updates = security.get("updates")
    if updates is not None and str(updates).lower() not in ("skip", "force"):
        errors.append("security.updates: must be 'skip' or 'force'")
    return errors


def _validate_wizard(wizard: Any) -> list[str]:
    if wizard is not None and not isinstance(wizard, bool):
        return ["first_login_wizard: must be true or false"]
    return []


def _validate_network(network: Any) -> list[str]:
    error = _mapping_error("network", network)
    if error or not network:
        return [error] if error else []

    errors = []
    for key in network:
        if key not in ("managed_by", "interfaces", "nameservers"):
            errors.append(f"network.{key}: unknown key")

    managed_by = network.get("managed_by")
    if managed_by is not None and str(managed_by) not in MANAGED_BY:
        errors.append(f"network.managed_by: must be one of {MANAGED_BY}")

    for server in network.get("nameservers") or []:
        try:
            ipaddress.ip_address(str(server))
        except ValueError:
            errors.append(f"network.nameservers: {server} is not an address")

    interfaces = network.get("interfaces")
    error = _mapping_error("network.interfaces", interfaces)
    if error:
        return errors + [error]
    for name, iface in (interfaces or {}).items():
        errors.extend(
            _validate_interface(
                f"network.interfaces.{name}", iface, str(managed_by or "")
            )
        )
    return errors


def _validate_interface(key: str, iface: Any, managed_by: str) -> list[str]:
    error = _mapping_error(key, iface)
    if error or not iface:
        return [error] if error else []

    errors = []
    for family in iface:
        if family not in ("ipv4", "ipv6"):
            errors.append(f"{key}.{family}: unknown key")
    errors.extend(_validate_family(f"{key}.ipv4", iface.get("ipv4"), 4))
    errors.extend(_validate_family(f"{key}.ipv6", iface.get("ipv6"), 6))

    ipv6 = iface.get("ipv6") or {}
    if managed_by == "file" and ipv6.get("method") == "static":
        errors.append(
            f"{key}.ipv6: static addresses cannot be written to"
            " /etc/network/interfaces by this version; use"
            " network.managed_by: host and set the address on the host"
        )
    return errors


def _validate_family(key: str, family: Any, version: int) -> list[str]:
    error = _mapping_error(key, family)
    if error or not family:
        return [error] if error else []

    methods = IPV4_METHODS if version == 4 else IPV6_METHODS
    errors = []
    for name in family:
        if name not in ("method", "address", "gateway"):
            errors.append(f"{key}.{name}: unknown key")

    method = family.get("method")
    if method is None or str(method) not in methods:
        errors.append(f"{key}.method: must be one of {methods}")
    if str(method) == "static" and "address" not in family:
        errors.append(f"{key}.address: required when method is static")

    if "address" in family:
        errors.extend(_address_errors(key, str(family["address"]), version))
    if "gateway" in family:
        errors.extend(_gateway_errors(key, str(family["gateway"]), version))
    return errors


def _address_errors(key: str, address: str, version: int) -> list[str]:
    if "/" not in address:
        return [f"{key}.address: prefix length is required ({address})"]
    try:
        value = ipaddress.ip_interface(address)
    except ValueError as e:
        return [f"{key}.address: {e}"]
    if value.version != version:
        return [f"{key}.address: not an IPv{version} address ({address})"]
    if version == 6 and not _is_unicast(value.ip):
        return [
            f"{key}.address: must be a unicast address, not link local,"
            f" loopback or multicast ({address})"
        ]
    return []


def _is_unicast(address: Any) -> bool:
    return not (
        address.is_link_local
        or address.is_loopback
        or address.is_multicast
        or address.is_unspecified
    )


def _gateway_errors(key: str, gateway: str, version: int) -> list[str]:
    try:
        value = ipaddress.ip_address(gateway)
    except ValueError as e:
        return [f"{key}.gateway: {e}"]
    if value.version != version:
        return [f"{key}.gateway: not an IPv{version} address ({gateway})"]
    return []


def _validate_tls(tls: Any) -> list[str]:
    error = _mapping_error("tls", tls)
    if error or not tls:
        return [error] if error else []

    errors = []
    for key in tls:
        if key != "acme":
            errors.append(f"tls.{key}: unknown key")

    acme = tls.get("acme")
    error = _mapping_error("tls.acme", acme)
    if error or not acme:
        return errors + ([error] if error else [])

    for key in acme:
        if key not in ("enabled", "challenge", "domains"):
            errors.append(f"tls.acme.{key}: unknown key")
    if acme.get("challenge") not in (None, "http-01", "dns-01"):
        errors.append("tls.acme.challenge: must be http-01 or dns-01")
    for domain in acme.get("domains") or []:
        error = _domain_error("tls.acme.domains", domain)
        if error:
            errors.append(error)
    return errors


def _validate_preseed(preseed: Any) -> list[str]:
    error = _mapping_error("preseed", preseed)
    if error or not preseed:
        return [error] if error else []
    return [
        f"preseed.{key}: not a valid variable name"
        for key in preseed
        if not _NAME_RE.match(str(key))
    ]
