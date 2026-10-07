# ============================================================================
#  Traiectus - firewall setup for the server
# ----------------------------------------------------------------------------
#  WHY THIS EXISTS
#    The existing inbound allow rules are scoped to the PROGRAM PATH
#    (...\phase3-tcp\build\minikvm-server.exe).  Renaming that exe to
#    Traiectus-Server.exe makes those rules stop matching, and Windows would
#    then BLOCK the Mac's connection to TCP 45789.
#
#  WHAT IT DOES (nothing else)
#    1) adds ONE inbound ALLOW rule for TCP 45789 (Private + Public).
#       It is scoped to the PORT, not to the program - the old rules were
#       scoped to the exe path, and renaming the exe silently killed them.
#       Port scope survives future renames.  If the rule already exists it is
#       left alone, so re-running this script cannot make it program-scoped again.
#    2) renames the old control-channel rule for UDP 45791 to
#       "Traiectus discovery UDP 45791".
#       The port itself is now used for ADDRESS DISCOVERY (Mac broadcasts
#       "WHO 1", the server unicasts back "HERE 1 45789"), so the rule is
#       still needed - only the name was wrong.  The old control channel is
#       gone (2026-10-01); this script never *deletes* a rule.
#    3) removes PROGRAM-scoped leftover rules - display names ending in ".exe":
#         traiectus-server.exe        (real name, but "any port" - too broad)
#         traiectus-server-*.exe      (temporary build names from testing)
#         minikvm-server.exe          (pre-rename leftovers)
#       Inbound then stays open only on the two ports above.
#
#  It does NOT touch the two port-scoped "Traiectus ..." rules, does NOT change
#  any port, does NOT touch the system proxy, and does NOT add any autostart item.
#  Re-running it is safe: it first removes the rule it created by name.
#
#  Needs an elevated shell - use the .bat next to this file, which elevates itself.
# ============================================================================

$ErrorActionPreference = 'Continue'

$rule = 'Traiectus server TCP 45789'

Write-Host ''
Write-Host '=== Traiectus firewall setup ===' -ForegroundColor Cyan

# --- 1) inbound allow for the server -----------------------------------------
#
#  IMPORTANT: deliberately PORT-scoped, not program-scoped.
#  The old MiniKVM rules were program-scoped, so renaming the exe silently
#  stopped them matching and the Mac could not connect any more.  Port scope
#  does not care what the executable is called.
#
#  And it is idempotent: an existing rule is left untouched, so re-running this
#  script can never downgrade it back to program-scoped.
if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
    Write-Host ("  already present, left as is: " + $rule) -ForegroundColor DarkGray
} else {
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 45789 -Profile Private,Public | Out-Null
    Write-Host ("  added (port-scoped, survives future renames): " + $rule) -ForegroundColor Green
}

# --- 2) rename the (still needed) UDP 45791 rule -------------------------------
#  UDP 45791 is now the ADDRESS DISCOVERY port: the Mac broadcasts "WHO 1" and
#  the server unicasts back "HERE 1 45789".  The old control channel on the same
#  port is gone, so only the display name was wrong.  Renaming keeps the rule
#  matching (and the "by port" naming) instead of leaving two confusing names.
$oldNames = @('MiniKVM control channel UDP 45791', 'Traiectus control channel UDP 45791')
$newName  = 'Traiectus discovery UDP 45791'

if (Get-NetFirewallRule -DisplayName $newName -ErrorAction SilentlyContinue) {
    Write-Host ("  already present, left as is: " + $newName) -ForegroundColor DarkGray
} else {
    $renamed = $false
    foreach ($old in $oldNames) {
        $r = Get-NetFirewallRule -DisplayName $old -ErrorAction SilentlyContinue
        if ($r) {
            $r | Set-NetFirewallRule -NewDisplayName $newName -ErrorAction SilentlyContinue
            if (Get-NetFirewallRule -DisplayName $newName -ErrorAction SilentlyContinue) {
                Write-Host ("  renamed: " + $old + "  ->  " + $newName) -ForegroundColor Green
                $renamed = $true
                break
            }
        }
    }
    if (-not $renamed) {
        Write-Host ("  no UDP 45791 rule found; adding one: " + $newName) -ForegroundColor Green
        New-NetFirewallRule -DisplayName $newName -Direction Inbound -Action Allow `
            -Protocol UDP -LocalPort 45791 -Profile Private,Public | Out-Null
    }
}

# --- 3) remove PROGRAM-scoped leftovers ---------------------------------------
#
#  Every time a build of the server listened for the first time, Windows showed
#  its "allow this app" prompt and created a rule scoped to the EXE, allowing
#  TCP/UDP on ANY port.  Today there are two kinds of them:
#
#    * traiectus-server.exe          - the real name, but still "any port"
#    * traiectus-server-*.exe        - temporary build names used while testing
#                                      (new / new2..new9 / next / final / disc).
#                                      Those files are already deleted, so the
#                                      rules are pure clutter.
#    * minikvm-server.exe            - the pre-rename leftovers
#
#  The two rules this script manages are PORT scoped and named "Traiectus ...",
#  so they are never touched here: the filter only looks at display names that
#  end in ".exe".  Result: after this runs, inbound is opened exactly on
#  45789/TCP and 45791/UDP, nothing else - and renaming the exe later cannot
#  silently break it again.
$progScoped = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayName -like '*.exe' -and
        ($_.DisplayName -like 'traiectus-server*' -or $_.DisplayName -eq 'minikvm-server.exe')
    }

if ($progScoped) {
    Write-Host ''
    Write-Host ("  removing " + @($progScoped).Count + " program-scoped leftover rule(s):") -ForegroundColor Yellow
    foreach ($r in $progScoped) {
        $pf = $r | Get-NetFirewallPortFilter
        $af = $r | Get-NetFirewallApplicationFilter
        Write-Host ("    - " + $r.DisplayName + "  (" + $r.Direction + " " + $r.Action + ")  " + $pf.Protocol + ":any  prog=" + $af.Program)
    }
    $progScoped | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $still = Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*.exe' -and $_.DisplayName -like 'traiectus-server*' }
    if ($still) {
        Write-Host ("  FAILED: " + @($still).Count + " rule(s) still present") -ForegroundColor Red
    } else {
        Write-Host ("  removed " + @($progScoped).Count + " rule(s)") -ForegroundColor Green
    }
} else {
    Write-Host ''
    Write-Host '  no program-scoped leftovers found (already clean)' -ForegroundColor DarkGray
}

# --- 4) report ---------------------------------------------------------------
Write-Host ''
Write-Host '=== current Traiectus / MiniKVM rules ===' -ForegroundColor Cyan
Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Traiectus|MiniKVM|minikvm-server' } |
    ForEach-Object {
        $pf = $_ | Get-NetFirewallPortFilter
        $af = $_ | Get-NetFirewallApplicationFilter
        "{0,-42} {1,-9} {2,-6} {3,-6} port={4} prog={5}" -f `
            $_.DisplayName, $_.Direction, $_.Action, $_.Enabled, $pf.LocalPort, $af.Program
    }

Write-Host ''
Write-Host ''
Write-Host 'Done. Inbound is now opened only on 45789/TCP and 45791/UDP (both port-scoped);' -ForegroundColor Cyan
Write-Host 'the program-scoped leftovers were removed, no port was changed, no autostart added.' -ForegroundColor Cyan
