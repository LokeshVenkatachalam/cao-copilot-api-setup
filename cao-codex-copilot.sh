#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
  echo "WARNING: Running as root. Installed tools will run with root privileges."
fi

export STACK_HOME="${STACK_HOME:-$HOME/.local/share/copilot-codex}"
ROOT="$STACK_HOME"
export COPILOT_API_HOME="$ROOT/gateway"
export PORT="${PORT:-4141}"
export MODEL="${MODEL:-}"
export CODEX_MODEL="${CODEX_MODEL:-$MODEL}"
export CLAUDE_MODEL="${CLAUDE_MODEL:-$MODEL}"

[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "PORT must be a number."
PORT=$((10#$PORT))
export PORT
(( PORT >= 1 && PORT <= 65535 )) || die "PORT must be 1-65535."

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "Use Linux, macOS, or WSL." ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Only x64 and ARM64 are supported by this installer." ;;
esac

for cmd in curl tar gzip awk mktemp; do
  command -v "$cmd" >/dev/null ||
    die "Missing '$cmd'. On Debian/Ubuntu: apt-get update && apt-get install -y curl ca-certificates tar gzip coreutils"
done

mkdir -p "$ROOT"/{bin,packages,gateway,codex,claude}
chmod 700 "$ROOT" "$ROOT/gateway" "$ROOT/codex" "$ROOT/claude"

TMP="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "\nFailed at line %s. Review the error above.\n" "$LINENO" >&2' ERR

export PATH="$ROOT/node/bin:$PATH"

# Use an existing recent Node runtime, or install a private Node 24 runtime.
if ! command -v npm >/dev/null ||
   ! node -e '
     process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)
   ' >/dev/null 2>&1; then
  echo "Installing Node.js 24 under $ROOT/node ..."

  NODE_URL="https://nodejs.org/dist/latest-v24.x"
  curl -q -fsSL --retry 3 \
    "$NODE_URL/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"

  ARCHIVE="$(awk -v suffix="-$OS-$ARCH.tar.gz" '
    substr($2,length($2)-length(suffix)+1)==suffix {
      print $2; exit
    }
  ' "$TMP/SHASUMS256.txt")"

  [[ "$ARCHIVE" =~ ^node-v24\.[0-9]+\.[0-9]+-${OS}-${ARCH}\.tar\.gz$ ]] ||
    die "Could not identify the Node.js download."

  curl -q -fsSL --retry 3 \
    "$NODE_URL/$ARCHIVE" -o "$TMP/$ARCHIVE"

  EXPECTED="$(awk -v name="$ARCHIVE" '$2==name {print $1}' \
    "$TMP/SHASUMS256.txt")"

  if command -v sha256sum >/dev/null; then
    ACTUAL="$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')"
  elif command -v shasum >/dev/null; then
    ACTUAL="$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')"
  else
    die "Install sha256sum or shasum to verify Node.js."
  fi

  [[ -n "$EXPECTED" && "$ACTUAL" == "$EXPECTED" ]] ||
    die "Node.js checksum mismatch."

  mkdir -p "$ROOT/node"
  tar -xzf "$TMP/$ARCHIVE" -C "$ROOT/node" --strip-components=1
  hash -r
fi

node --version
node -e 'require("node:sqlite")' >/dev/null 2>&1 ||
  die "Node cannot load node:sqlite; persistent token history needs it."

NODE_BIN="$(dirname "$(command -v node)")"

# Abort before changing installed packages or configuration if the port is occupied.
node <<'JS'
const net = require("node:net");
const server = net.createServer();
server.once("error", error => {
  console.error(`Port ${process.env.PORT} unavailable: ${error.message}`);
  console.error("Stop the existing gateway before rerunning this installer.");
  process.exit(1);
});
server.listen(Number(process.env.PORT), "127.0.0.1", () => server.close());
JS

echo "Installing Codex CLI, Claude Code, and Copilot API..."
npm install --global --prefix "$ROOT/packages" \
  '@openai/codex@latest' \
  '@anthropic-ai/claude-code@latest' \
  '@jeffreycao/copilot-api@latest'

export PATH="$ROOT/bin:$ROOT/packages/bin:$NODE_BIN:$PATH"

# This helper contains paths, not credentials.
{
  printf 'export STACK_HOME=%q\n' "$ROOT"
  printf 'export COPILOT_API_HOME=%q\n' "$COPILOT_API_HOME"
  printf "export PATH=%q:\"\$PATH\"\n" \
    "$ROOT/bin:$ROOT/packages/bin:$NODE_BIN"
} > "$ROOT/env.sh"

printf '%s\n' "$PORT" > "$ROOT/port"

# Generate or reuse a random gateway key and preserve existing gateway settings.
node <<'JS'
const fs = require("node:fs");
const crypto = require("node:crypto");
const root = process.env.STACK_HOME;
const keyPath = `${root}/gateway.key`;
const configPath = `${root}/gateway/config.json`;

if (!fs.existsSync(keyPath)) {
  fs.writeFileSync(
    keyPath,
    `cp_${crypto.randomBytes(32).toString("hex")}\n`,
    { mode: 0o600, flag: "wx" },
  );
}
const key = fs.readFileSync(keyPath, "utf8").trim();
if (!/^cp_[a-f0-9]{64}$/.test(key)) {
  throw new Error(`Unexpected key format in ${keyPath}; inspect it locally.`);
}
fs.chmodSync(keyPath, 0o600);

const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, "utf8"))
  : {};
if (fs.existsSync(configPath)) {
  fs.copyFileSync(configPath, `${configPath}.backup-${Date.now()}`);
}
config.auth ??= {};
config.auth.apiKeys = [...new Set([...(config.auth.apiKeys ?? []), key])];
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
fs.chmodSync(configPath, 0o600);

// Keep the credential out of curl's command-line arguments.
fs.writeFileSync(
  `${root}/curl.conf`,
  'header = "Authorization: Bearer ' + key + '"\n',
);
fs.chmodSync(`${root}/curl.conf`, 0o600);
JS

echo
echo "Authenticate the gateway with your GitHub Copilot account."
echo "Follow the device/browser authorization instructions."
"$ROOT/packages/bin/copilot-api" auth login --provider copilot

cat > "$ROOT/bin/start-copilot-api" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
exec "$ROOT/packages/bin/copilot-api" start \
  --host 127.0.0.1 --port "$(cat "$ROOT/port")"
SH

cat > "$ROOT/bin/codex-copilot" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
export CODEX_HOME="$ROOT/codex"
exec "$ROOT/packages/bin/codex" "$@"
SH

cat > "$ROOT/bin/claude-copilot" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
source "$ROOT/claude/env.sh"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
exec "$ROOT/packages/bin/claude" "$@"
SH

cat > "$ROOT/bin/copilot-usage" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec curl -q --noproxy '*' --fail --silent --show-error \
  --connect-timeout 5 --max-time 60 \
  --config "$ROOT/curl.conf" \
  "http://127.0.0.1:$(cat "$ROOT/port")/usage"
SH

cat > "$ROOT/bin/copilot-key" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cat "$ROOT/gateway.key"
SH

chmod 700 "$ROOT/bin/"*

echo "Starting a temporary gateway to discover your Copilot models..."
"$ROOT/bin/start-copilot-api" > "$ROOT/setup-server.log" 2>&1 &
SERVER_PID=$!
BASE="http://127.0.0.1:$PORT"
READY=0

for ((i=0; i<60; i++)); do
  kill -0 "$SERVER_PID" 2>/dev/null ||
    die "Gateway exited. Inspect $ROOT/setup-server.log locally."

  if curl -q --noproxy '*' -fsS \
      --connect-timeout 1 --max-time 3 \
      --config "$ROOT/curl.conf" "$BASE/v1/models" \
      > "$TMP/models.json" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done

[[ "$READY" == 1 ]] ||
  die "Gateway not ready. Inspect $ROOT/setup-server.log locally."

# Discover available models instead of assuming account entitlements.
node - "$TMP/models.json" <<'JS'
const fs = require("node:fs");
const root = process.env.STACK_HOME;
const response = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const models = (response.data ?? []).filter(model =>
  typeof model.id === "string" &&
  !model.id.includes("/") &&
  model.capabilities?.supports?.tool_calls !== false
);

if (!models.length) {
  throw new Error("No compatible Copilot models returned. Check account access.");
}

const supports = (model, endpoints) =>
  (model.supported_endpoints ?? []).some(endpoint => endpoints.has(endpoint));
const responses = new Set(["/responses", "/v1/responses", "ws:/responses"]);
const messages = new Set([
  "/v1/messages",
  "/messages",
  "/chat/completions",
  "/v1/chat/completions",
]);
const codexModels = models.filter(model => supports(model, responses));
const claudeModels = models.filter(model => supports(model, messages));

const select = (available, requested, preferred, label) => {
  const selected = requested
    ? available.find(model => model.id === requested)
    : available.find(preferred) ?? available[0];
  if (!selected) {
    const suffix = requested ? `: ${requested}` : "";
    throw new Error(`No compatible ${label} model is available${suffix}`);
  }
  return selected;
};

const codex = select(
  codexModels,
  process.env.CODEX_MODEL,
  model => model.id.startsWith("gpt-"),
  "Codex",
);
const claude = select(
  claudeModels,
  process.env.CLAUDE_MODEL,
  model => model.id.startsWith("claude-") || model.id.startsWith("gpt-"),
  "Claude Code",
);

console.log("\nAvailable Copilot model IDs:");
for (const model of models) console.log(`  ${model.id}`);

const codexConfigPath = `${root}/codex/config.toml`;
if (fs.existsSync(codexConfigPath)) {
  fs.copyFileSync(codexConfigPath, `${codexConfigPath}.backup-${Date.now()}`);
}
const codexConfig = `
model = ${JSON.stringify(codex.id)}
model_provider = "copilot_api"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[model_providers.copilot_api]
name = "OpenAI"
base_url = "http://127.0.0.1:${process.env.PORT}"
wire_api = "responses"
supports_websockets = false
request_max_retries = 3
stream_max_retries = 3
stream_idle_timeout_ms = 300000

[model_providers.copilot_api.auth]
command = "/bin/cat"
args = [${JSON.stringify(`${root}/gateway.key`)}]

[features]
apps = false

[analytics]
enabled = false
`;
fs.writeFileSync(codexConfigPath, codexConfig.trimStart(), { mode: 0o600 });
fs.chmodSync(codexConfigPath, 0o600);

const key = fs.readFileSync(`${root}/gateway.key`, "utf8").trim();
const shellExport = (name, value) =>
  `export ${name}=${JSON.stringify(value)}\n`;
const claudeEnv = [
  shellExport("ANTHROPIC_BASE_URL", `http://127.0.0.1:${process.env.PORT}`),
  shellExport("ANTHROPIC_AUTH_TOKEN", key),
  shellExport("ANTHROPIC_MODEL", claude.id),
  shellExport("ANTHROPIC_DEFAULT_OPUS_MODEL", claude.id),
  shellExport("ANTHROPIC_DEFAULT_SONNET_MODEL", claude.id),
  shellExport("ANTHROPIC_DEFAULT_HAIKU_MODEL", claude.id),
  shellExport("CLAUDE_CODE_USE_VERTEX", "0"),
  shellExport("CLAUDE_CODE_USE_BEDROCK", "0"),
  shellExport("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
  shellExport("CLAUDE_CODE_ATTRIBUTION_HEADER", "0"),
].join("");
fs.writeFileSync(`${root}/claude/env.sh`, claudeEnv, { mode: 0o600 });
fs.chmodSync(`${root}/claude/env.sh`, 0o600);

console.log(`\nCodex default: ${codex.id}`);
console.log(`Claude Code default: ${claude.id}`);
JS

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo
echo "========== SETUP COMPLETE =========="
echo "The temporary gateway has been stopped."
printf '\nTerminal 1:\n  source %q\n  start-copilot-api\n' "$ROOT/env.sh"
printf '\nTerminal 2, inside your project:\n'
printf '  source %q\n  codex-copilot\n' "$ROOT/env.sh"
printf '\nOr run Claude Code:\n'
printf '  source %q\n  claude-copilot\n' "$ROOT/env.sh"
printf '\nUsage dashboard:\n%s/usage-viewer?endpoint=%s/usage\n' "$BASE" "$BASE"
echo
echo "Usage JSON:      copilot-usage"
echo "Show saved key:  copilot-key"
echo "State directory: $ROOT"
echo "Setup log:       $ROOT/setup-server.log"
