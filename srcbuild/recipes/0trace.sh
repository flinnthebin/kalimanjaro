#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${NAME:=0trace}"
: "${DEP_NAME:=sendprobe}"
: "${PREFIX:=/usr/local}"
: "${BIN:=${PREFIX}/bin}"
: "${MAN:=${PREFIX}/share/man/man1}"
: "${DEP:=libexec}"
: "${SRC:?set by srcbuild}"
: "${REPO:=http://lcamtuf.coredump.cx/soft/0trace.tgz}"
: "${FILE:=0trace.sh}"
: "${PANDOC_MAN:=0}"
: "${SECTION:=1}"
# ---------- env ----------

deps() { cat <<'EOF'
curl
tar
gzip
gcc
libcap
pandoc
gzip
man-db
EOF
}

_install_manpage_from_pandoc() {
  require_cmd pandoc
  local tmp_md="${SRC}/${NAME}_man.md"
  local out_man="${SRC}/${NAME}.${SECTION}"

  cat >"$tmp_md" <<'MD'
% 0TRACE(1) 0trace |  Manual 
# NAME  
0trace — traceroute on established connections  
  
# USAGE  
**0trace** *interface* *target_ip*  
  
Run a TCP client to the target (e.g., telnet to port 80), then in another terminal:  
send a simple request (e.g., `GET / HTTP/1.0`) to keep the connection alive while  
0trace probes using TTL-stepped packets tied to the existing TCP flow.  
  
# NOTES  
May not work if ICMP is blocked, TTL is rewritten, an app-layer proxy/LB intervenes,  
or there’s no interesting layer-3 infra behind the firewall.  
  
# SOURCE  
Upstream tarball: <http://lcamtuf.coredump.cx/soft/0trace.tgz>  
  
# ORIGINAL ANNOUNCEMENT  
I'd like to announce the availability of a free security reconnaissance /  
firewall bypassing tool called 0trace. This tool enables the user to  
perform hop enumeration ("traceroute") within an established TCP  
connection, such as a HTTP or SMTP session. This is opposed to sending  
stray packets, as traceroute-type tools usually do.  
  
The important benefit of using an established connection and matching TCP  
packets to send a TTL-based probe is that such traffic is happily allowed  
through by many stateful firewalls and other defenses without further  
inspection (since it is related to an entry in the connection table).  
  
I'm not aware of any public implementations of this technique, even though  
the concept itself is making rounds since 2000 or so; because of this, I  
thought it might be a good idea to give it a try.  
  
[ Of course, I might be wrong, but Google seems to agree with my  
  assessment. A related use of this idea is 'firewalk' by Schiffman and  
  Goldsmith, a tool to probe firewall ACLs; another utility called  
  'tcptraceroute' by Michael C. Toren implements TCP SYN probes, but since  
  the tool does not ride an existing connection, it is less likely to  
  succeed (sometimes a handshake must be completed with the NAT device  
  before any traffic is forwarded). ]  
  
A good example of the difference is www.ebay.com (66.135.192.124) - a  
regular UDP/ICMP traceroute and tcptraceroute both end like this:  
  
14  as-0-0.bbr1.SanJose1.Level3.net (64.159.1.133)  ...  
15  ae-12-53.car2.SanJose1.Level3.net (4.68.123.80) ...  
16  * * *  
17  * * *  
18  * * *  
  
Let's do the same using 0trace: we first manually telnet to 66.135.192.124  
to port 80, then execute: './0trace.sh eth0 66.135.192.124', and finally  
enter 'GET / HTTP/1.0' (followed by a single, not two newlines) to solicit  
some client-server traffic but keep the session alive for the couple of  
seconds 0trace needs to complete the probe.  
  
The output is as follows:  
  
10 80.91.249.14    
11 213.248.65.210  
12 213.248.83.66  
13 4.68.110.81  
14 4.68.97.33  
15 64.159.1.130  
16 4.68.123.48  
17 166.90.140.134 <---  
18 10.6.1.166     <--- new data  
19 10.6.1.70      <---  
Target reached.  
  
The last three lines reveal firewalled infrastructure, including private  
addresses used on the inside of the company. This is obviously an  
important piece of information as far as penetration testing is concerned.  
  
Of course, 0trace won't work everywhere and all the time. The tool will  
not produce interesting results in the following situations:  
  
  - Target's firewall drops all outgoing ICMP messages,  
  
  - Target's firewall does TTL or full-packet rewriting,  
  
  - There's an application layer proxy / load balancer in the way  
    (Akamai, in-house LBs, etc),  
  
  - There's no notable layer 3 infrastructure behind the firewall.  
  
The tool also has a fairly distinctive TCP signature, and as such, it can  
be detected by IDS/IPS systems.  
  
Enough chatter - the tool is available here (Linux version):  
  
  http://lcamtuf.coredump.cx/soft/0trace.tgz  
  
Note: this is a 30-minute hack that involves C code coupled with a cheesy  
shellscript. It may not work on non-Linux systems, and may fail on some  
Linuxes, too. It could be improved in a number of ways - so if you like  
it, rewrite it.  
  
Many thanks for Robert Swiecki (www.swiecki.net) for forcing me to  
finally give this idea some thought and develop this piece.  
  
Cheers,  
/mz  
MD

  log "[${NAME}] generating manpage via pandoc"
  quiet_run pandoc -s -t man "$tmp_md" -o "$out_man"

  quiet_run gzip -f -9 "$out_man"
  quiet_run with_sudo install -Dm644 "${out_man}.gz" \
    "${MAN}/${NAME}.${SECTION}.gz"

  # touch man-db (best-effort)
  if command -v mandb >/dev/null 2>&1; then
    quiet_run with_sudo mandb || true
  fi
}

pre() {
  log "[{$NAME}] preflight: check upstream tarball"
  curl -fsI "${REPO}" >/dev/null || warn "[${NAME}] HEAD failed for ${REPO} (will try anyway)"
}

fetch() {
  require_cmd curl
  require_cmd tar
  log "[${NAME}] fetching sources from upstream"
  mkdir -p "${SRC}"
  local tgz="${SRC}/${NAME}.tgz"
  quiet_run curl -fL "${REPO}" -o "$tgz"
  quiet_run tar -xzf "$tgz" -C "$SRC"
  [[ -d "${SRC}/${NAME}" ]] || die "[{$NAME}] expected directory {$SRC}/${NAME} missing after extract"
}

build() {
  log "[${NAME}] compiling ${DEP_NAME} & patching script"
  (
    cd "$SRC/${NAME}"
    quiet_run gcc -O2 -Wall -o "${DEP_NAME}" "${DEP_NAME}".c

    # Patch 0trace.sh so it uses an installed helper:
    # - add PROBE default to PREFIX/libexec/0trace/sendprobe
    # - replace ./sendprobe with "$PROBE"
    quiet_run sed -E \
      -e "1i PROBE=\${PROBE:-\"${PREFIX}\"/${DEP}/${NAME}/${DEP_NAME}}" \
      -e 's#\./sendprobe#"$PROBE"#g' \
      ${FILE} > ${NAME}.patched
    chmod +x ${NAME}.patched
  )
}

install() {
  log "[$NAME] installing"
  quiet_run with_sudo install -Dm755 "${SRC}/${NAME}/${DEP_NAME}" "$PREFIX/${DEP}/${NAME}/${DEP_NAME}"
  quiet_run with_sudo install -Dm755 "$SRC/${NAME}/${NAME}.patched" "${BIN}/$NAME"
  quiet_run with_sudo setcap cap_net_raw+ep "${PREFIX}/${DEP}/${NAME}/${DEP_NAME}" || warn "[${NAME}] setcap failed; run ${NAME} with sudo"
  log "[${NAME}] adding manpage"
  _install_manpage_from_pandoc
  log "[${NAME}] installed to ${BIN}/${NAME}"
}

post() {
  log "[${NAME}] post: smoke"
  command -v "${BIN}/${NAME}" >/dev/null || die "[${NAME}] binary missing"
  "${BIN}/${NAME}" -h >/dev/null || true
  if command -v getcap >/dev/null; then
    getcap "${PREFIX}/${DEP}/${NAME}/${DEP_NAME}" | grep -q cap_net_raw || warn "[${NAME}] ${DEP_NAME} missing cap_net_raw"
  fi
}

uninstall() {
  log "[${NAME}] removing installed files"
  rm_if_exists \
    "${BIN}/${NAME}" \
    "$PREFIX/${DEP}/${NAME}/${DEP_NAME}" \
    "${MAN}/${NAME}.${SECTION}.gz"
  rmdir_safe "$PREFIX/${DEP}/${NAME}"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac

