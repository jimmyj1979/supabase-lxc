#!/usr/bin/env bash
#
# supabase_configure.sh — post-install configuration for a Supabase LXC
#
# Run INSIDE the Supabase container (pct enter <CTID> first):
#   bash supabase_configure.sh
#
# The deploy script offers to fetch and run this at the end of an install.
#
# Configures, each section skippable and safe to re-run:
#   * Resend        — SMTP for email verification, plus branded templates
#   * Twilio        — SMS OTP on signup and TOTP 2FA
#   * Storage       — upload size limit and image transformation
#   * Edge Funcs    — JWT verification and a scaffolded function
#
# Nothing is applied until the end, and only the affected services are
# recreated. The existing .env is backed up first.

set -euo pipefail

SCRIPT_NAME="supabase_configure.sh"

# ------------------------------------------------------------------ output ---
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
info()  { echo "${BLU}==>${RST} $*"; }
ok()    { echo "${GRN} ok${RST} $*"; }
warn()  { echo "${YLW}  !${RST} $*"; }
die()   { echo "${RED}  x${RST} $*" >&2; exit 1; }
# pct exec gives the script no TTY, so Enter arrives as a carriage return and
# lands inside the value. Strip it, plus surrounding whitespace, or secrets get
# written to .env with an invisible  on the end.
clean() { local v="$1"; v="${v%$''}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
ask()   { local p="$1" d="${2:-}" a; read -rp "$p${d:+ [$d]}: " a; a=$(clean "$a"); printf '%s' "${a:-$d}"; }
# Deliberately NOT hidden. pct exec gives no TTY, so a hidden prompt shows no
# feedback at all and a paste that fails to register looks identical to one
# that worked -- which is how an empty key reached .env once. The value is
# visible on screen and in scrollback; the secrets are in .env anyway.
asks()  { local p="$1" a; read -rp "$p: " a; clean "$a"; }
yes?()  { local a; read -rp "$1 [y/N] " a; [[ "${a,,}" == "y" ]]; }

# ------------------------------------------------------------------- where ---
# This runs INSIDE the Supabase container, not on the Proxmox host. The deploy
# script offers to fetch and run it for you at the end of an install; otherwise
# get into the container first with `pct enter <CTID>`.
[ "$(id -u)" -eq 0 ] || die "Run as root."

if command -v pveversion >/dev/null 2>&1; then
  die "This runs inside the Supabase container, not on the Proxmox host. Use: pct enter <CTID>"
fi
command -v docker >/dev/null 2>&1   || die "No docker here — this must run inside the Supabase container."

run() { "$@"; }

# The installer uses /opt/supabase-project; containers built by other helper
# scripts commonly use /root/supabase-project. Find whichever is really there.
PROJECT_DIR=""
for d in /opt/supabase-project /root/supabase-project /opt/supabase/docker; do
  if run test -f "$d/.env" 2>/dev/null; then PROJECT_DIR="$d"; break; fi
done
[ -n "$PROJECT_DIR" ] || die "No Supabase project (.env) found in this container."
ENVF="$PROJECT_DIR/.env"
OVRF="$PROJECT_DIR/docker-compose.override.yml"
ok "Project: $PROJECT_DIR"

# Some settings are hardcoded in upstream's docker-compose.yml rather than read
# from .env — FILE_SIZE_LIMIT and ENABLE_IMAGE_TRANSFORMATION among them — so
# writing those to .env has no effect at all. They have to be overridden in
# docker-compose.override.yml, which Compose merges automatically and which
# upstream's update.sh leaves alone.
#
# The override file is regenerated whole on each run, so pick up what a previous
# run put there; otherwise skipping a section here would silently drop it.
OVR_TPL=0; OVR_FSL=""; OVR_IMG=""; OVR_AUTH=""
if run test -f "$OVRF" 2>/dev/null; then
  run grep -q 'auth/templates' "$OVRF" 2>/dev/null && OVR_TPL=1
  # recover forwarded auth vars so a skipped section does not drop them
  OVR_AUTH=$(run sh -c "grep -oE '^ +GOTRUE_[A-Z0-9_]+:' '$OVRF' 2>/dev/null | tr -d ' :' | tr '
' ' '" || true)
  OVR_FSL=$(run sh -c "grep -m1 'FILE_SIZE_LIMIT:' '$OVRF' 2>/dev/null | sed 's/.*: *//'" || true)
  OVR_IMG=$(run sh -c "grep -m1 'ENABLE_IMAGE_TRANSFORMATION:' '$OVRF' 2>/dev/null | sed 's/.*: *//' | tr -d '\"'" || true)
fi

# upstream's docker-compose.yml gives auth an explicit environment: block, so a
# GOTRUE_* variable added to .env alone never reaches the container -- it is
# simply not passed through. Anything we set has to be forwarded here too.
auth_env() { case " $OVR_AUTH " in *" $1 "*) ;; *) OVR_AUTH="$OVR_AUTH $1" ;; esac; }

# A GOTRUE_* var this script manages may already be in .env from an earlier run.
# The override is rewritten whole each time, so forward those too -- otherwise
# skipping a section on a later run silently stops passing what it set before.
for _v in GOTRUE_SMS_PROVIDER           GOTRUE_SMS_TWILIO_ACCOUNT_SID GOTRUE_SMS_TWILIO_AUTH_TOKEN GOTRUE_SMS_TWILIO_MESSAGE_SERVICE_SID           GOTRUE_SMS_TWILIO_VERIFY_ACCOUNT_SID GOTRUE_SMS_TWILIO_VERIFY_AUTH_TOKEN GOTRUE_SMS_TWILIO_VERIFY_MESSAGE_SERVICE_SID           GOTRUE_SMS_MAX_FREQUENCY GOTRUE_SMS_OTP_EXP GOTRUE_SMS_OTP_LENGTH           GOTRUE_MFA_ENABLED GOTRUE_MFA_MAX_ENROLLED_FACTORS           GOTRUE_MFA_PHONE_ENROLL_ENABLED GOTRUE_MFA_PHONE_VERIFY_ENABLED           GOTRUE_MAILER_TEMPLATES_CONFIRMATION GOTRUE_MAILER_TEMPLATES_RECOVERY           GOTRUE_MAILER_TEMPLATES_INVITE GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE; do
  run grep -q "^$_v=" "$ENVF" 2>/dev/null && auth_env "$_v"
done

write_override() {
  local y="services:"
  if [ "$OVR_TPL" = 1 ] || [ -n "$OVR_AUTH" ]; then
    y="$y
  auth:"
    [ "$OVR_TPL" = 1 ] && y="$y
    volumes:
      - ./volumes/auth/templates:/etc/gotrue/templates:ro"
    if [ -n "$OVR_AUTH" ]; then
      y="$y
    environment:"
      for v in $OVR_AUTH; do
        # value stays in .env; compose substitutes it here
        y="$y
      $v: \${$v}"
      done
    fi
  fi
  if [ -n "$OVR_FSL" ] || [ -n "$OVR_IMG" ]; then
    y="$y
  storage:
    environment:"
    [ -n "$OVR_FSL" ] && y="$y
      FILE_SIZE_LIMIT: $OVR_FSL"
    [ -n "$OVR_IMG" ] && y="$y
      ENABLE_IMAGE_TRANSFORMATION: \"$OVR_IMG\""
  fi
  [ "$y" = "services:" ] && return 0
  run env _F="$OVRF" _Y="$y" sh -c 'printf "%s\n" "$_Y" > "$_F"'
  ok "Wrote $(basename "$OVRF")"

  # Compose only auto-includes docker-compose.override.yml when COMPOSE_FILE is
  # unset. Upstream sets COMPOSE_FILE=docker-compose.yml, which silently
  # disables that — the override file is written and then completely ignored.
  local cf
  cf=$(get_env COMPOSE_FILE)
  if [ -z "$cf" ]; then
    : # unset: Compose picks the override up on its own
  elif case ":$cf:" in *":docker-compose.override.yml:"*) true ;; *) false ;; esac; then
    : # already listed
  else
    set_env COMPOSE_FILE "$cf:docker-compose.override.yml"
    ok "Appended docker-compose.override.yml to COMPOSE_FILE"
  fi
}

# ------------------------------------------------------------- env helpers ---
# Replace a key in place, or append it. The value travels through the
# environment and is read via awk's ENVIRON, so characters that would otherwise
# need escaping (/ + = & backslashes, common in base64 secrets) pass through
# untouched. sed would mangle several of these.
set_env() {
  local k="$1" v="$2"
  run env _K="$k" _V="$v" _F="$ENVF" sh -c '
    if grep -q "^${_K}=" "$_F"; then
      awk -v k="$_K" '\''BEGIN{v=ENVIRON["_V"]} $0 ~ "^" k "=" {print k "=" v; next} {print}'\'' "$_F" > "$_F.tmp" \
        && cat "$_F.tmp" > "$_F" && rm -f "$_F.tmp"
    else
      printf "%s=%s\n" "$_K" "$_V" >> "$_F"
    fi'
}
get_env() { run sh -c "grep -m1 '^$1=' '$ENVF' | cut -d= -f2-" 2>/dev/null || true; }

TOUCHED=""   # services needing recreation
touch_svc() { case " $TOUCHED " in *" $1 "*) ;; *) TOUCHED="$TOUCHED $1" ;; esac; }

# ------------------------------------------------------------------ backup ---
BAK="$ENVF.bak-$(date +%Y%m%d-%H%M%S)"
run cp "$ENVF" "$BAK"
ok "Backed up .env to $BAK"
echo

# ==================================================================== RESEND ==
if yes? "Configure Resend for transactional email?"; then
  info "Resend uses the literal username 'resend'; the password is an API key."
  warn "The From address must be on a domain verified in your Resend account,"
  warn "or Resend silently rejects the mail and signups appear to hang."

  # Input is hidden, so a paste that silently failed used to be written to .env
  # as-is and only surfaced when mail stopped working. Check the shape instead.
  while :; do
    RS_KEY=$(asks "  Resend API key (re_...)")
    [ -n "$RS_KEY" ] || die "No API key given."
    case "$RS_KEY" in
      re_*) ok "Captured a key of ${#RS_KEY} characters starting 're_'." ; break ;;
      *)    warn "Captured ${#RS_KEY} character(s), not starting with 're_'."
            warn "Resend keys always begin 're_' — if your paste did not register, try again." ;;
    esac
  done

  while :; do
    RS_FROM=$(ask  "  From address (on your verified domain)")
    [ -n "$RS_FROM" ] || die "No From address given."
    case "$RS_FROM" in
      *@*.*) break ;;
      *) warn "'$RS_FROM' is not an email address — it needs to look like noreply@example.com." ;;
    esac
  done
  RS_NAME=$(ask  "  Sender name" "Supabase")

  set_env SMTP_HOST         "smtp.resend.com"
  set_env SMTP_PORT         "587"
  set_env SMTP_USER         "resend"
  set_env SMTP_PASS         "$RS_KEY"
  set_env SMTP_ADMIN_EMAIL  "$RS_FROM"
  set_env SMTP_SENDER_NAME  "$RS_NAME"
  # Verification is pointless if signups are auto-confirmed.
  set_env ENABLE_EMAIL_SIGNUP      "true"
  set_env ENABLE_EMAIL_AUTOCONFIRM "false"
  touch_svc auth
  ok "Resend configured; email confirmation is now required."

  # ---- templates ----
  if yes? "  Install branded email templates?"; then
    TPL="$PROJECT_DIR/volumes/auth/templates"
    SITE=$(get_env SITE_URL)
    run mkdir -p "$TPL"

    # GoTrue renders these with Go templating. {{ .ConfirmationURL }} is the
    # action link; {{ .Token }} is the 6-digit code if you prefer codes.
    for t in confirmation:"Confirm your email":"Confirm your email address to finish signing up." \
             recovery:"Reset your password":"Click below to choose a new password." \
             invite:"You have been invited":"You have been invited to create an account." \
             email_change:"Confirm your new email":"Confirm this address to complete the change."; do
      name="${t%%:*}"; rest="${t#*:}"; head="${rest%%:*}"; body="${rest#*:}"
      run env _P="$TPL/$name.html" _H="$head" _B="$body" _S="$SITE" sh -c '
        cat > "$_P" <<EOF
<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f6f7f9;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1f2328">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" style="max-width:520px;background:#fff;border-radius:10px;padding:32px">
          <tr><td>
            <h1 style="margin:0 0 12px;font-size:20px;font-weight:600">$_H</h1>
            <p style="margin:0 0 24px;font-size:15px;line-height:1.55;color:#4a5159">$_B</p>
            <p style="margin:0 0 24px">
              <a href="{{ .ConfirmationURL }}"
                 style="display:inline-block;background:#1f2328;color:#fff;text-decoration:none;padding:11px 20px;border-radius:7px;font-size:15px">$_H</a>
            </p>
            <p style="margin:0;font-size:13px;line-height:1.5;color:#6b7280">
              If the button does not work, paste this into your browser:<br>
              <span style="word-break:break-all">{{ .ConfirmationURL }}</span>
            </p>
            <p style="margin:24px 0 0;font-size:13px;color:#6b7280">
              Did not request this? You can safely ignore this email.
            </p>
          </td></tr>
        </table>
        <p style="margin:16px 0 0;font-size:12px;color:#9aa1a9">$_S</p>
      </td></tr>
    </table>
  </body>
</html>
EOF'
    done

    # Templates are inert unless GoTrue is told where they are AND they are
    # mounted into the container. The mount goes in the override file.
    OVR_TPL=1
    set_env GOTRUE_MAILER_TEMPLATES_CONFIRMATION "/etc/gotrue/templates/confirmation.html"
    auth_env GOTRUE_MAILER_TEMPLATES_CONFIRMATION
    set_env GOTRUE_MAILER_TEMPLATES_RECOVERY     "/etc/gotrue/templates/recovery.html"
    auth_env GOTRUE_MAILER_TEMPLATES_RECOVERY
    set_env GOTRUE_MAILER_TEMPLATES_INVITE       "/etc/gotrue/templates/invite.html"
    auth_env GOTRUE_MAILER_TEMPLATES_INVITE
    set_env GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE "/etc/gotrue/templates/email_change.html"
    auth_env GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE
    ok "Templates written to volumes/auth/templates and mounted at /etc/gotrue/templates."

    CF=$(get_env COMPOSE_FILE)
    case "$CF" in
      *override*|"") : ;;
      *) warn "COMPOSE_FILE is set explicitly and does not list the override file."
         warn "Compose will ignore docker-compose.override.yml — append it to COMPOSE_FILE." ;;
    esac
  fi
fi
echo

# ==================================================================== TWILIO ==
if yes? "Configure Twilio for SMS OTP and 2FA?"; then
  info "Twilio Verify is recommended: Twilio generates, sends and checks the"
  info "code, and handles rate limiting. Its service SID starts with VA."
  info "Plain Programmable Messaging uses a Messaging Service SID (MG)."
  TW_MODE=$(ask "  Mode: 'verify' or 'messaging'" "verify")

  TW_SID=$(ask  "  Twilio Account SID (AC...)")
  [ -n "$TW_SID" ] || die "No Account SID given."
  case "$TW_SID" in AC*) : ;; *) warn "Account SIDs normally start with 'AC' — '$TW_SID' may be wrong." ;; esac
  TW_TOK=$(asks "  Twilio Auth Token")
  [ -n "$TW_TOK" ] || die "No Auth Token given."
  ok "Captured a token of ${#TW_TOK} characters."

  if [ "$TW_MODE" = "messaging" ]; then
    TW_SVC=$(ask "  Messaging Service SID (MG...)")
    set_env GOTRUE_SMS_PROVIDER                 "twilio"
    auth_env GOTRUE_SMS_PROVIDER
    set_env GOTRUE_SMS_TWILIO_ACCOUNT_SID       "$TW_SID"
    auth_env GOTRUE_SMS_TWILIO_ACCOUNT_SID
    set_env GOTRUE_SMS_TWILIO_AUTH_TOKEN        "$TW_TOK"
    auth_env GOTRUE_SMS_TWILIO_AUTH_TOKEN
    set_env GOTRUE_SMS_TWILIO_MESSAGE_SERVICE_SID "$TW_SVC"
    auth_env GOTRUE_SMS_TWILIO_MESSAGE_SERVICE_SID
  else
    TW_SVC=$(ask "  Verify Service SID (VA...)")
    # GoTrue reads a DIFFERENT set of variables per provider. Selecting
    # "twilio" while setting the _VERIFY_ variables leaves it with no
    # credentials at all — a silent misconfiguration.
    set_env GOTRUE_SMS_PROVIDER                        "twilio_verify"
    auth_env GOTRUE_SMS_PROVIDER
    set_env GOTRUE_SMS_TWILIO_VERIFY_ACCOUNT_SID       "$TW_SID"
    auth_env GOTRUE_SMS_TWILIO_VERIFY_ACCOUNT_SID
    set_env GOTRUE_SMS_TWILIO_VERIFY_AUTH_TOKEN        "$TW_TOK"
    auth_env GOTRUE_SMS_TWILIO_VERIFY_AUTH_TOKEN
    set_env GOTRUE_SMS_TWILIO_VERIFY_MESSAGE_SERVICE_SID "$TW_SVC"
    auth_env GOTRUE_SMS_TWILIO_VERIFY_MESSAGE_SERVICE_SID
  fi
  case "$TW_SVC" in
    VA*) [ "$TW_MODE" = "verify" ]    || warn "SID looks like a Verify service but mode is 'messaging'." ;;
    MG*) [ "$TW_MODE" = "messaging" ] || warn "SID looks like a Messaging service but mode is 'verify'." ;;
  esac

  set_env ENABLE_PHONE_SIGNUP "true"
  # Autoconfirm marks a phone verified WITHOUT sending or checking an OTP,
  # which defeats the entire point of configuring Twilio.
  set_env ENABLE_PHONE_AUTOCONFIRM "false"
  set_env GOTRUE_SMS_MAX_FREQUENCY "60s"
  auth_env GOTRUE_SMS_MAX_FREQUENCY
  set_env GOTRUE_SMS_OTP_EXP       "60"
  auth_env GOTRUE_SMS_OTP_EXP
  set_env GOTRUE_SMS_OTP_LENGTH    "6"
  auth_env GOTRUE_SMS_OTP_LENGTH
  ok "SMS OTP enabled; phone numbers must now be verified."

  if yes? "  Enable TOTP 2FA (authenticator apps)?"; then
    set_env GOTRUE_MFA_ENABLED              "true"
    auth_env GOTRUE_MFA_ENABLED
    set_env GOTRUE_MFA_MAX_ENROLLED_FACTORS "10"
    auth_env GOTRUE_MFA_MAX_ENROLLED_FACTORS
    if yes? "  Also allow SMS as a second factor (costs per message)?"; then
      set_env GOTRUE_MFA_PHONE_ENROLL_ENABLED "true"
      auth_env GOTRUE_MFA_PHONE_ENROLL_ENABLED
      set_env GOTRUE_MFA_PHONE_VERIFY_ENABLED "true"
      auth_env GOTRUE_MFA_PHONE_VERIFY_ENABLED
    fi
    ok "MFA enabled. Drive it client-side with auth.mfa.enroll/challenge/verify,"
    ok "and enforce aal2 in RLS rather than trusting the client."
  fi
  touch_svc auth
fi
echo

# =================================================================== STORAGE ==
if yes? "Configure Storage limits?"; then
  # Upstream hardcodes these in docker-compose.yml, so they are set through the
  # override file rather than .env. The live container is the honest source for
  # what is in effect right now.
  CUR=$(run docker inspect supabase-storage \
          --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
          | sed -n 's/^FILE_SIZE_LIMIT=//p' | head -1)
  info "Current upload limit: ${CUR:-unknown} bytes ($(( ${CUR:-0} / 1048576 )) MB)"
  MB=$(ask "  Max upload size in MB" "50")
  case "$MB" in ''|*[!0-9]*) die "Not a number: $MB" ;; esac
  OVR_FSL="$(( MB * 1048576 ))"
  if yes? "  Enable image transformation (resize/format on the fly)?"; then
    OVR_IMG="true"
    set_env IMGPROXY_AUTO_WEBP "true"   # this one IS read from .env
    touch_svc imgproxy
  else
    OVR_IMG="false"
  fi
  touch_svc storage
  warn "Storage uses the 'file' backend at volumes/storage inside the container."
  warn "That directory is on the container rootfs and is NOT in any snapshot"
  warn "of your app database — back it up separately if it holds real files."
  ok "Storage limit set to ${MB} MB."
fi
echo

# ============================================================= EDGE FUNCTIONS ==
if yes? "Configure Edge Functions?"; then
  VJ=$(get_env FUNCTIONS_VERIFY_JWT)
  info "FUNCTIONS_VERIFY_JWT is currently: ${VJ:-unset}"
  if [ "$VJ" != "true" ]; then
    warn "With this false, every deployed function is callable by anyone who can"
    warn "reach the gateway, with no token. Turn it on unless you specifically"
    warn "want public webhook endpoints."
  fi
  if yes? "  Require a valid JWT for function calls?"; then
    set_env FUNCTIONS_VERIFY_JWT "true"
  else
    set_env FUNCTIONS_VERIFY_JWT "false"
  fi

  if yes? "  Scaffold a new function?"; then
    FN=$(ask "  Function name" "my-function")
    case "$FN" in ''|*[!a-zA-Z0-9_-]*) die "Invalid function name: $FN" ;; esac
    FD="$PROJECT_DIR/volumes/functions/$FN"
    if run test -d "$FD"; then
      warn "$FN already exists — left untouched."
    else
      run mkdir -p "$FD"
      run env _P="$FD/index.ts" _N="$FN" sh -c 'cat > "$_P" <<EOF
// $_N — served at /functions/v1/$_N
Deno.serve(async (req) => {
  const { name = "world" } = await req.json().catch(() => ({}))
  return new Response(
    JSON.stringify({ message: \`hello \${name}\`, fn: "$_N" }),
    { headers: { "Content-Type": "application/json" } },
  )
})
EOF'
      ok "Created volumes/functions/$FN/index.ts"
    fi
  fi
  touch_svc functions
  info "Functions are mounted from volumes/functions — edit on disk, then"
  info "restart edge-functions. There is no separate deploy step."
fi
echo

# ===================================================================== APPLY ==
[ -n "$TOUCHED" ] || { ok "Nothing changed."; exit 0; }

write_override

info "Services to recreate:$TOUCHED"
warn "Compose bakes environment into a container when it is created, so these"
warn "must be recreated rather than restarted."
yes? "Apply now?" || { warn "Not applied. Your edits are in $ENVF."; \
                       warn "Apply later with: cd $PROJECT_DIR && docker compose up -d$TOUCHED"; exit 0; }

run sh -c "cd $PROJECT_DIR && docker compose up -d$TOUCHED"
sleep 5

echo
info "Verifying"
for s in $TOUCHED; do
  case "$s" in
    auth)      C=supabase-auth ;;
    storage)   C=supabase-storage ;;
    functions) C=supabase-edge-functions ;;   # service "functions", container "supabase-edge-functions"
    imgproxy)  C=supabase-imgproxy ;;
    *)         C="supabase-$s" ;;
  esac
  ST=$(run docker inspect "$C" --format '{{.State.Status}}' 2>/dev/null || echo missing)
  [ "$ST" = "running" ] && ok "$C: $ST" || warn "$C: $ST — check: docker logs $C --tail 50"
done

if case " $TOUCHED " in *" auth "*) true ;; *) false ;; esac; then
  echo
  info "Auth settings now live in the container:"
  run docker inspect supabase-auth \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -E '^GOTRUE_(SMS_PROVIDER|SMS_AUTOCONFIRM|MAILER_AUTOCONFIRM|MFA_ENABLED)=' \
    | sed 's/^/    /' || true
  if run test -n "$(run docker inspect supabase-auth --format '{{len .Mounts}}' 2>/dev/null)"; then
    run docker inspect supabase-auth \
      --format '{{range .Mounts}}    mount: {{.Source}} -> {{.Destination}}{{println}}{{end}}' || true
  fi
fi

echo
ok "Done. Previous .env is at $BAK"
warn "Send yourself a signup and a password reset before trusting this in anger."
