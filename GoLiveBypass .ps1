# =====================================================================
#  GoLiveBypass Standalone
#
#  Credits:
#    detrew ("https://github.com/bezumiya/GoLiveBypass")
#    vithor176 ("so roubei o metodo kk")
#
#  Modos:
#    Menu         -> mostra Permanent / Temporary / Restore
#    Permanent    -> instala launcher persistente + comando "golive"
#    Temporary    -> injeta somente nesta execucao e restaura ao fechar
#    PermanentRun -> usado pelo launcher persistente
#    Restore      -> remove loader, atalhos, launcher e restaura Discord
# =====================================================================

param(
    [ValidateSet("Menu", "Permanent", "Temporary", "PermanentRun", "Restore")]
    [string]$Mode = "Menu"
)

$ErrorActionPreference = "Stop"

$InstallRoot = Join-Path $env:LOCALAPPDATA "GoLiveBypass"
$PermanentScript = Join-Path $InstallRoot "GoLiveBypass.ps1"
$CommandFile = Join-Path $InstallRoot "golive.cmd"
$StateFile = Join-Path (Join-Path $env:APPDATA "discord") "golive-bypass-state.json"
$LogFile = Join-Path $env:TEMP "golive-bypass.log"

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host "                 GoLiveBypass Standalone      " -ForegroundColor Cyan
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Credits:" -ForegroundColor Gray
    Write-Host "    detrew " -NoNewline -ForegroundColor Magenta
    Write-Host '("https://github.com/bezumiya/GoLiveBypass")' -ForegroundColor DarkGray
    Write-Host "    vithor176 " -NoNewline -ForegroundColor Magenta
    Write-Host '("so roubei o metodo kk")' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      Discord direto -> call -> proxy -> reload -> direct" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  AVISO:" -ForegroundColor Yellow
    Write-Host "    Ao entrar na call, o Discord pode ficar em loading por alguns" -ForegroundColor Yellow
    Write-Host "    segundos enquanto reconecta pela proxy. Isso e normal." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Get-LatestDiscordApp {
    $discordRoot = Join-Path $env:LOCALAPPDATA "Discord"

    if (!(Test-Path $discordRoot)) {
        throw "Discord nao encontrado em: $discordRoot"
    }

    $appDir = Get-ChildItem $discordRoot -Directory |
        Where-Object { $_.Name -match '^app-[0-9]' } |
        Sort-Object {
            try { [version]($_.Name -replace '^app-', '') }
            catch { [version]'0.0.0' }
        } -Descending |
        Select-Object -First 1

    if (!$appDir) {
        throw "Nenhuma pasta app-* do Discord foi encontrada."
    }

    return $appDir
}

function Test-IsOurLoader([string]$LoaderDir) {
    $pkg = Join-Path $LoaderDir "package.json"
    if (!(Test-Path $pkg)) {
        return $false
    }

    try {
        $json = Get-Content $pkg -Raw | ConvertFrom-Json
        return $json.name -eq "golive-bypass-standalone"
    } catch {
        return $false
    }
}

function Stop-Discord {
    Get-Process Discord -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 1200
}

function Write-LoaderFiles([string]$LoaderDir) {
    New-Item -ItemType Directory -Path $LoaderDir -Force | Out-Null

    $packageJson = @'
{
  "name": "golive-bypass-standalone",
  "version": "1.0.0",
  "main": "index.js"
}
'@

    $settingsJson = @'
{
  "proxy": "",
  "freeProxyProtocol": "socks5",
  "excludedCountries": "BR"
}
'@

    [IO.File]::WriteAllText(
        (Join-Path $LoaderDir "package.json"),
        $packageJson,
        [Text.UTF8Encoding]::new($false)
    )

    [IO.File]::WriteAllText(
        (Join-Path $LoaderDir "settings.json"),
        $settingsJson,
        [Text.UTF8Encoding]::new($false)
    )

    $indexJs = @'
const fs = require("fs");
const path = require("path");
const { app, session } = require("electron");
const { request } = require("https");
const { connect } = require("net");

const FREE_PROXY_API = "https://api.proxyscrape.com/v4/free-proxy-list/get";
const MAX_LIST_BYTES = 1024 * 1024;
const MAX_PROXY_CANDIDATES = 8;
const PROXY_TEST_TIMEOUT_MS = 5000;
const WATCHDOG_TIMEOUT_MS = 120_000;
const LAST_APPLY_GRACE_MS = 3 * 60_000;
const VALID_PROTOCOLS = new Set(["http", "socks4", "socks5"]);
const PROXY_RULES_RE = /^(socks4|socks5|https?):\/\/([^/\s]{1,253}):(\d{1,5})$/;

const SETTINGS_FILE = path.join(__dirname, "settings.json");
const STATE_DIR = path.join(process.env.APPDATA || __dirname, "discord");
const STATE_FILE = path.join(STATE_DIR, "golive-bypass-state.json");
const LOG_FILE = path.join(process.env.TEMP || __dirname, "golive-bypass.log");

try { fs.mkdirSync(STATE_DIR, { recursive: true }); } catch {}

let preparedProxy = "";
let preparingProxy = null;
let proxyApplied = false;
let switchingForCall = false;
let waitingForConnectionOpen = false;
let reloadNavigationStarted = false;
let clearInProgress = false;
let watchdog;
let currentVoiceChannelId = null;
let voiceReconnectedAfterCycle = false;
let skipAutomaticProxyThisBoot = false;

function log(message) {
    const line = `[${new Date().toISOString()}] ${message}`;
    try { fs.appendFileSync(LOG_FILE, line + "\n"); } catch {}
    try { console.log("[GoLiveBypass]", message); } catch {}
}

function readJson(file, fallback = {}) {
    try {
        if (!fs.existsSync(file)) return fallback;
        const text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
        return JSON.parse(text);
    } catch (e) {
        log(`Failed reading ${file}: ${e.message}`);
        return fallback;
    }
}

function writeJson(file, data) {
    try {
        fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
    } catch (e) {
        log(`Failed writing ${file}: ${e.message}`);
    }
}

const settings = readJson(SETTINGS_FILE, {
    proxy: "",
    freeProxyProtocol: "socks5",
    excludedCountries: "BR"
});
const state = readJson(STATE_FILE, {});

function saveState() { writeJson(STATE_FILE, state); }
function readStoredProxy() {
    const proxy = state.lastKnownProxy;
    return typeof proxy === "string" && PROXY_RULES_RE.test(proxy) ? proxy : "";
}
function storeProxy(proxy) {
    state.lastKnownProxy = proxy;
    saveState();
    log(`Stored working proxy: ${proxy}`);
}
function forgetStoredProxy() {
    delete state.lastKnownProxy;
    saveState();
}
function setLastApply() {
    state.lastApply = Date.now();
    saveState();
}
function clearLastApply() {
    delete state.lastApply;
    saveState();
}

function parseProxy(proxyRules) {
    const match = PROXY_RULES_RE.exec(proxyRules);
    if (!match) return null;
    const port = Number(match[3]);
    if (port < 1 || port > 65535) return null;
    return { scheme: match[1], host: match[2], port };
}

function connectThroughProxy(scheme, host, port, target, targetPort) {
    return new Promise(resolve => {
        const socket = connect({ host, port });
        let settled = false;

        // socket.setTimeout() is an inactivity timeout. Keep the original
        // behavior, but also enforce the intended 5-second wall-clock limit.
        const hardDeadline = setTimeout(
            () => done(false),
            PROXY_TEST_TIMEOUT_MS
        );

        const done = ok => {
            if (settled) return;
            settled = true;
            clearTimeout(hardDeadline);
            try { socket.destroy(); } catch {}
            resolve(ok);
        };

        socket.setTimeout(PROXY_TEST_TIMEOUT_MS, () => done(false));
        socket.on("error", () => done(false));

        socket.once("connect", () => {
            if (scheme === "http" || scheme === "https") {
                socket.once("data", res => done(/^HTTP\/1\.[01] 200/.test(res.toString("latin1"))));
                socket.write(`CONNECT ${target}:${targetPort} HTTP/1.1\r\nHost: ${target}:${targetPort}\r\n\r\n`);
                return;
            }

            if (scheme === "socks5") {
                socket.once("data", greeting => {
                    if (greeting.length < 2 || greeting[1] !== 0) return done(false);

                    const hostBuf = Buffer.from(target, "latin1");
                    socket.once("data", res => done(res.length >= 2 && res[1] === 0));
                    socket.write(Buffer.concat([
                        Buffer.from([0x05, 0x01, 0x00, 0x03, hostBuf.length]),
                        hostBuf,
                        Buffer.from([targetPort >> 8, targetPort & 0xff])
                    ]));
                });
                socket.write(Buffer.from([0x05, 0x01, 0x00]));
                return;
            }

            const hostBuf = Buffer.from(target, "latin1");
            socket.once("data", res => done(res.length >= 2 && res[1] === 0x5a));
            socket.write(Buffer.concat([
                Buffer.from([0x04, 0x01, targetPort >> 8, targetPort & 0xff, 0, 0, 0, 1, 0]),
                hostBuf,
                Buffer.from([0])
            ]));
        });
    });
}

function downloadText(url) {
    return new Promise((resolve, reject) => {
        const req = request(url, res => {
            if (res.statusCode !== 200) {
                res.resume();
                return reject(new Error("Unexpected response status"));
            }

            let size = 0;
            const chunks = [];
            res.on("data", chunk => {
                size += chunk.length;
                if (size > MAX_LIST_BYTES)
                    req.destroy(new Error("Response too large"));
                else
                    chunks.push(chunk);
            });
            res.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
        });
        req.on("error", reject);
        req.setTimeout(15000, () => req.destroy(new Error("Request timed out")));
        req.end();
    });
}

function parseFreeProxyList(body) {
    const data = JSON.parse(body);
    if (typeof data !== "object" || data === null) return [];
    const { proxies } = data;
    if (!Array.isArray(proxies)) return [];

    const entries = [];
    for (const item of proxies) {
        if (typeof item !== "object" || item === null) continue;
        const { proxy, ip_data } = item;
        if (typeof proxy !== "string" || !PROXY_RULES_RE.test(proxy)) continue;

        const countryCode = typeof ip_data === "object" && ip_data !== null
            && typeof ip_data.countryCode === "string"
            ? ip_data.countryCode.toUpperCase()
            : "";

        entries.push({ proxy, countryCode });
    }
    return entries;
}

async function fetchFreeProxy(protocol, excludedCountries) {
    if (typeof protocol !== "string" || !VALID_PROTOCOLS.has(protocol))
        return { success: false, error: "Unsupported proxy protocol." };

    const excluded = new Set(
        typeof excludedCountries === "string"
            ? excludedCountries.split(",").map(c => c.trim().toUpperCase()).filter(c => /^[A-Z]{2}$/.test(c))
            : []
    );

    let body;
    try {
        log("Fetching free proxy list...");
        body = await downloadText(`${FREE_PROXY_API}?request=display_proxies&protocol=${protocol}&proxy_format=protocolipport&format=json&timeout=5000`);
    } catch {
        return { success: false, error: "Failed to fetch the free proxy list." };
    }

    let proxies;
    try {
        proxies = parseFreeProxyList(body)
            .filter(e => !e.countryCode || !excluded.has(e.countryCode))
            .map(e => e.proxy);
    } catch {
        return { success: false, error: "Failed to parse the free proxy list." };
    }

    if (!proxies.length)
        return { success: false, error: "The free proxy list had no proxies outside the excluded countries." };

    log(`Proxy list: ${proxies.length} candidates`);

    for (let i = proxies.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [proxies[i], proxies[j]] = [proxies[j], proxies[i]];
    }

    for (const candidate of proxies.slice(0, MAX_PROXY_CANDIDATES)) {
        const parsed = parseProxy(candidate);
        if (!parsed) continue;

        log(`Testing ${candidate}`);
        if (await connectThroughProxy(parsed.scheme, parsed.host, parsed.port, "discord.com", 443)) {
            log(`Working proxy found: ${candidate}`);
            return { success: true, proxy: candidate };
        }
        log(`Proxy failed: ${candidate}`);
    }

    return { success: false, error: "No working proxy found outside the excluded countries." };
}

async function prepareProxy() {
    const manual = typeof settings.proxy === "string" ? settings.proxy.trim() : "";

    if (manual) {
        if (!parseProxy(manual)) {
            log("Configured manual proxy is invalid.");
            return "";
        }
        preparedProxy = manual;
        return manual;
    }

    if (skipAutomaticProxyThisBoot) return "";
    if (preparedProxy && parseProxy(preparedProxy)) return preparedProxy;
    if (preparingProxy) return preparingProxy;

    preparingProxy = (async () => {
        const stored = readStoredProxy();
        if (stored) {
            // Mirrors the original earlyProxy()/earlyApply() behavior:
            // reuse lastKnownProxy immediately instead of retesting it here.
            preparedProxy = stored;
            log(`Stored proxy READY immediately: ${stored}`);
            return stored;
        }

        const result = await fetchFreeProxy(
            settings.freeProxyProtocol || "socks5",
            settings.excludedCountries || "BR"
        );

        if (!result.success) {
            log(`Could not prepare proxy: ${result.error}`);
            return "";
        }

        preparedProxy = result.proxy;
        storeProxy(result.proxy);
        log(`Proxy READY for next call: ${result.proxy}`);
        return result.proxy;
    })();

    try {
        return await preparingProxy;
    } finally {
        preparingProxy = null;
    }
}

function stopWatchdog() {
    if (watchdog !== undefined) {
        clearTimeout(watchdog);
        watchdog = undefined;
    }
}

function startWatchdog() {
    stopWatchdog();
    watchdog = setTimeout(() => {
        if (!proxyApplied) return;
        log("Watchdog timed out waiting for proxied CONNECTION_OPEN.");
        clearGoLiveBypass("timeout", true).catch(() => {});
    }, WATCHDOG_TIMEOUT_MS);
}

async function applyProxyForCall(proxy) {
    await session.defaultSession.setProxy({ proxyRules: proxy });
    proxyApplied = true;
    log(`PROXY ACTIVE: ${proxy}`);

    // This mid-session standalone flow already has pooled direct sockets.
    // Closing them is what forces the reconnect/reload to use the new proxy.
    try {
        await session.defaultSession.closeAllConnections();
        log("Existing Chromium connections closed.");
    } catch (e) {
        log(`closeAllConnections warning: ${e.message}`);
    }
}

async function clearGoLiveBypass(reason, rearm = false) {
    if (clearInProgress || !proxyApplied) return;
    clearInProgress = true;
    stopWatchdog();

    try {
        log(`Clearing proxy (${reason})`);
        await session.defaultSession.setProxy({ mode: "direct" });
        proxyApplied = false;
        waitingForConnectionOpen = false;
        reloadNavigationStarted = false;
        clearLastApply();
        log(`PROXY OFF (${reason}). Direct connection restored.`);
        if (rearm) {
            currentVoiceChannelId = null;
            voiceReconnectedAfterCycle = false;
        }
    } catch (e) {
        log(`Failed clearing proxy: ${e.stack || e}`);
    } finally {
        clearInProgress = false;
    }
}

async function switchForCall(contents, channelId) {
    if (switchingForCall || waitingForConnectionOpen || proxyApplied) return;
    switchingForCall = true;
    currentVoiceChannelId = channelId || currentVoiceChannelId || "unknown";
    voiceReconnectedAfterCycle = false;

    try {
        log(`Voice call detected${channelId ? ` (channel ${channelId})` : ""}.`);

        if (preparingProxy && !preparedProxy)
            log("Proxy is still being prepared; call trigger is waiting for it.");

        const proxy = await prepareProxy();
        if (!proxy) {
            log("No proxy available for call refresh.");
            currentVoiceChannelId = null;
            return;
        }

        await applyProxyForCall(proxy);
        waitingForConnectionOpen = true;
        reloadNavigationStarted = false;
        setLastApply();
        startWatchdog();

        if (!contents || contents.isDestroyed()) {
            log("Target webContents was destroyed before reload.");
            await clearGoLiveBypass("renderer unavailable", true);
            return;
        }

        const onNavigation = (...navArgs) => {
            let isMainFrame = false;

            // Current Electron: (event, details)
            if (navArgs.length >= 2 && navArgs[1] && typeof navArgs[1] === "object" && typeof navArgs[1].isMainFrame === "boolean")
                isMainFrame = navArgs[1].isMainFrame;
            // Older/deprecated form: (event, url, isInPlace, isMainFrame, ...)
            else if (navArgs.length >= 4)
                isMainFrame = navArgs[3] === true;

            if (isMainFrame) {
                reloadNavigationStarted = true;
                log("Reload navigation started under proxy.");
            }
        };

        contents.once("did-start-navigation", onNavigation);

        log("Reloading Discord renderer under proxy...");
        contents.reload();
    } catch (e) {
        log(`Call proxy refresh failed: ${e.stack || e}`);
        if (proxyApplied) await clearGoLiveBypass("switch failed", true);
        else currentVoiceChannelId = null;
    } finally {
        switchingForCall = false;
    }
}

function getConsoleMessage(args) {
    // Current Electron: (event, details)
    if (args.length >= 2 && args[1] && typeof args[1] === "object" && typeof args[1].message === "string")
        return args[1].message;

    // Older/deprecated form: (event, level, message, line, sourceId)
    if (args.length >= 3 && typeof args[2] === "string")
        return args[2];

    return "";
}

function extractVoiceChannelId(message) {
    const match = message.match(/Connecting to RTC server .*?channel:\s*(\d+)\(/);
    return match ? match[1] : null;
}

function attachDiscordEvents(contents) {
    contents.on("console-message", (...args) => {
        const message = getConsoleMessage(args);
        if (!message) return;

        if (message.includes("Connecting to RTC server")) {
            const channelId = extractVoiceChannelId(message);

            // Same call reconnecting after our reload: do not trigger another cycle.
            if (currentVoiceChannelId && channelId && currentVoiceChannelId === channelId) {
                if (!switchingForCall) voiceReconnectedAfterCycle = true;
                return;
            }

            if (!switchingForCall && !waitingForConnectionOpen && !proxyApplied)
                switchForCall(contents, channelId).catch(e => log(`switchForCall error: ${e.stack || e}`));

            return;
        }

        if (
            waitingForConnectionOpen &&
            reloadNavigationStarted &&
            (
                message.includes("Dispatching CONNECTION_OPEN") ||
                message.includes("handleConnectionOpen called")
            )
        ) {
            log("Detected proxied CONNECTION_OPEN");
            clearGoLiveBypass("session ready").catch(() => {});
            return;
        }

        if (message.includes("Dispatching LOGIN_SUCCESS") && proxyApplied) {
            log("Detected proxied LOGIN_SUCCESS");
            clearGoLiveBypass("login finished").catch(() => {});
            return;
        }

        if (
            message.includes("VOICE_DISCONNECT") &&
            voiceReconnectedAfterCycle &&
            !switchingForCall &&
            !waitingForConnectionOpen
        ) {
            if (currentVoiceChannelId !== null) {
                log("Voice call ended. Call trigger rearmed.");
                currentVoiceChannelId = null;
                voiceReconnectedAfterCycle = false;
            }
        }
    });
}

const asarPath = path.join(__dirname, "..", "_app.asar");
const discordPackage = require(path.join(asarPath, "package.json"));
const originalMain = path.join(asarPath, discordPackage.main);

app.setAppPath(asarPath);
require.main.filename = originalMain;

app.on("web-contents-created", (_event, contents) => {
    attachDiscordEvents(contents);
});

// Preserve the original grace behavior after an unfinished proxied attempt.
const manual = typeof settings.proxy === "string" ? settings.proxy.trim() : "";
if (!manual) {
    const lastApply = typeof state.lastApply === "number" ? state.lastApply : 0;
    if (lastApply && Date.now() - lastApply < LAST_APPLY_GRACE_MS) {
        clearLastApply();
        skipAutomaticProxyThisBoot = true;
        log("Previous proxied attempt did not finish. Automatic proxy preparation skipped for this boot.");
    }
}

log("Loading Discord normally (direct connection)...");
require(originalMain);
log("Discord original loaded.");

app.whenReady().then(() => {
    if (skipAutomaticProxyThisBoot) return;

    log("Preparing proxy in background...");
    prepareProxy().catch(e => log(`Background proxy preparation failed: ${e.stack || e}`));
});

app.on("before-quit", () => {
    stopWatchdog();
});
'@

    [IO.File]::WriteAllText(
        (Join-Path $LoaderDir "index.js"),
        $indexJs,
        [Text.UTF8Encoding]::new($false)
    )
}

function Install-IntoDiscord([System.IO.DirectoryInfo]$AppDir) {
    $resources  = Join-Path $AppDir.FullName "resources"
    $appAsar    = Join-Path $resources "app.asar"
    $backupAsar = Join-Path $resources "_app.asar"
    $loaderDir  = Join-Path $resources "app"

    if ((Test-Path $backupAsar) -and (Test-IsOurLoader $loaderDir)) {
        Write-Host "  [*] GoLiveBypass existente detectado; atualizando loader..." -ForegroundColor DarkGray
        Write-LoaderFiles $loaderDir
        Write-Host "  [OK] Loader atualizado em $($AppDir.Name)." -ForegroundColor Green
        return
    }

    if ((Test-Path $appAsar) -and (Test-Path $backupAsar)) {
        throw "Estado ambiguo em $($AppDir.Name): app.asar e _app.asar existem juntos."
    }

    if (!(Test-Path $backupAsar)) {
        if (!(Test-Path $appAsar)) {
            throw "app.asar nao encontrado em $($AppDir.Name)."
        }

        Write-Host "  [*] app.asar -> _app.asar" -ForegroundColor DarkGray
        Move-Item $appAsar $backupAsar
    }

    if (Test-Path $loaderDir) {
        Remove-Item $loaderDir -Recurse -Force
    }

    Write-LoaderFiles $loaderDir

    Write-Host "  [OK] Loader instalado em $($AppDir.Name)." -ForegroundColor Green
}

function Restore-App([System.IO.DirectoryInfo]$AppDir) {
    $resources  = Join-Path $AppDir.FullName "resources"
    $appAsar    = Join-Path $resources "app.asar"
    $backupAsar = Join-Path $resources "_app.asar"
    $loaderDir  = Join-Path $resources "app"

    if (Test-IsOurLoader $loaderDir) {
        Remove-Item $loaderDir -Recurse -Force
    }

    if ((Test-Path $backupAsar) -and !(Test-Path $appAsar)) {
        Move-Item $backupAsar $appAsar
        Write-Host "  [OK] $($AppDir.Name) restaurado." -ForegroundColor Green
    }
}

function Restore-AllDiscordVersions {
    $discordRoot = Join-Path $env:LOCALAPPDATA "Discord"
    if (!(Test-Path $discordRoot)) {
        return
    }

    Get-ChildItem $discordRoot -Directory |
        Where-Object { $_.Name -match '^app-[0-9]' } |
        ForEach-Object {
            try { Restore-App $_ }
            catch { Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Yellow }
        }
}

function Get-DesktopShortcutPath {
    $desktop = [Environment]::GetFolderPath("Desktop")
    return (Join-Path $desktop "GoLive Discord.lnk")
}

function Get-StartMenuShortcutPath {
    $programs = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    return (Join-Path $programs "GoLive Discord.lnk")
}

function New-GoLiveShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)

    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PermanentScript`" -Mode PermanentRun"
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = (Join-Path (Get-LatestDiscordApp).FullName "Discord.exe")
    $shortcut.Description = "Discord com GoLiveBypass Standalone"
    $shortcut.Save()
}

function Add-GoLiveToUserPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()

    if ($userPath) {
        $parts = $userPath.Split(";") | Where-Object { $_ -and $_.Trim() }
    }

    $exists = $parts | Where-Object {
        $_.TrimEnd("\") -ieq $InstallRoot.TrimEnd("\")
    }

    if (!$exists) {
        $newPath = if ($userPath) { "$userPath;$InstallRoot" } else { $InstallRoot }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
}

function Remove-GoLiveFromUserPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (!$userPath) {
        return
    }

    $parts = $userPath.Split(";") |
        Where-Object {
            $_ -and
            $_.Trim() -and
            $_.TrimEnd("\") -ine $InstallRoot.TrimEnd("\")
        }

    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

function Install-PermanentFiles {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    if ($PSCommandPath) {
        $sourcePath = [IO.Path]::GetFullPath($PSCommandPath)
        $destPath = [IO.Path]::GetFullPath($PermanentScript)

        if ($sourcePath -ine $destPath) {
            Copy-Item $sourcePath $destPath -Force
        }
    } else {
        throw "Nao consegui determinar o caminho deste instalador."
    }

    $cmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PermanentScript" -Mode PermanentRun
"@

    [IO.File]::WriteAllText(
        $CommandFile,
        $cmd,
        [Text.ASCIIEncoding]::new()
    )

    Add-GoLiveToUserPath

    try { New-GoLiveShortcut (Get-DesktopShortcutPath) } catch {}
    try { New-GoLiveShortcut (Get-StartMenuShortcutPath) } catch {}

    Write-Host "  [OK] Launcher permanente salvo em:" -ForegroundColor Green
    Write-Host "       $InstallRoot" -ForegroundColor DarkGray
    Write-Host "  [OK] Comando instalado: golive" -ForegroundColor Green
    Write-Host "  [OK] Atalho: GoLive Discord" -ForegroundColor Green
}

function Remove-PermanentFiles {
    try {
        $desktop = Get-DesktopShortcutPath
        if (Test-Path $desktop) { Remove-Item $desktop -Force }
    } catch {}

    try {
        $startMenu = Get-StartMenuShortcutPath
        if (Test-Path $startMenu) { Remove-Item $startMenu -Force }
    } catch {}

    Remove-GoLiveFromUserPath

    if (Test-Path $InstallRoot) {
        # Do not remove the currently executing script immediately.
        # Schedule deletion after this PowerShell exits.
        $cleanup = Join-Path $env:TEMP "golive-cleanup.cmd"
        $cleanupBody = @"
@echo off
ping 127.0.0.1 -n 3 >nul
rmdir /s /q "$InstallRoot"
del /q "%~f0"
"@
        [IO.File]::WriteAllText($cleanup, $cleanupBody, [Text.ASCIIEncoding]::new())
        Start-Process $cleanup -WindowStyle Hidden
    }
}

function Start-Discord([System.IO.DirectoryInfo]$AppDir) {
    $exe = Join-Path $AppDir.FullName "Discord.exe"
    Write-Host ""
    Write-Host "  Abrindo Discord..." -ForegroundColor Cyan
    Start-Process $exe
}

function Wait-DiscordExitStable {
    Write-Host ""
    Write-Host "  Modo temporario ativo." -ForegroundColor Yellow
    Write-Host "  O loader sera removido quando o Discord ENCERRAR de verdade." -ForegroundColor DarkGray
    Write-Host "  Fechar apenas a janela para a bandeja nao conta como encerramento." -ForegroundColor DarkGray
    Write-Host ""

    $zeroCount = 0

    while ($true) {
        $running = Get-Process Discord -ErrorAction SilentlyContinue

        if ($running) {
            $zeroCount = 0
        } else {
            $zeroCount++
            if ($zeroCount -ge 5) {
                break
            }
        }

        Start-Sleep -Seconds 1
    }
}

function Invoke-PermanentRun {
    $appDir = Get-LatestDiscordApp

    if (Get-Process Discord -ErrorAction SilentlyContinue) {
        Write-Host "  Discord ja esta aberto." -ForegroundColor Yellow
        Write-Host "  Se houve update e voce quer reaplicar o loader, feche o Discord e rode 'golive' novamente." -ForegroundColor DarkGray
        return
    }

    Install-IntoDiscord $appDir

    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    }

    Start-Discord $appDir
}

function Invoke-PermanentInstall {
    Stop-Discord

    $appDir = Get-LatestDiscordApp

    Install-IntoDiscord $appDir
    Install-PermanentFiles

    Write-Host ""
    Write-Host "  PERMANENTE instalado." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Depois disso, para abrir:" -ForegroundColor Gray
    Write-Host "      golive" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Se o Discord atualizar para outra app-x.x.x:" -ForegroundColor Gray
    Write-Host "      rode golive novamente; ele encontra e injeta na versao nova." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Observacao: abra um NOVO PowerShell para o comando golive entrar no PATH." -ForegroundColor DarkGray

    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    }

    Start-Discord $appDir
}

function Invoke-Temporary {
    Stop-Discord

    $appDir = Get-LatestDiscordApp

    $resourcesBefore = Join-Path $appDir.FullName "resources"
    $loaderBefore = Join-Path $resourcesBefore "app"
    $backupBefore = Join-Path $resourcesBefore "_app.asar"
    $wasAlreadyPatched = (Test-Path $backupBefore) -and (Test-IsOurLoader $loaderBefore)

    Install-IntoDiscord $appDir

    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    }

    Start-Discord $appDir

    Wait-DiscordExitStable

    if ($wasAlreadyPatched) {
        Write-Host ""
        Write-Host "  Discord encerrado. A instalacao ja era permanente; mantendo loader." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "  Discord encerrado. Restaurando instalacao original..." -ForegroundColor Yellow

    Restore-App $appDir

    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  [OK] Modo temporario removido." -ForegroundColor Green
}

function Invoke-Restore {
    Write-Host "  Fechando Discord..." -ForegroundColor Yellow
    Stop-Discord

    Write-Host "  Restaurando todas as versoes encontradas..." -ForegroundColor Gray
    Restore-AllDiscordVersions

    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }

    Remove-PermanentFiles

    Write-Host ""
    Write-Host "  [OK] GoLiveBypass removido." -ForegroundColor Green

    try {
        $appDir = Get-LatestDiscordApp
        Start-Discord $appDir
    } catch {}
}

function Show-Menu {
    Write-Host "  Escolha o modo:" -ForegroundColor White
    Write-Host ""
    Write-Host "    [1] Permanente" -ForegroundColor Green
    Write-Host "        Instala o loader + comando 'golive' + atalhos." -ForegroundColor DarkGray
    Write-Host "        O comando reaplica automaticamente na versao mais nova do Discord." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    [2] Temporario" -ForegroundColor Yellow
    Write-Host "        Funciona somente ate o Discord encerrar; depois restaura app.asar." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    [3] Restaurar / remover tudo" -ForegroundColor Red
    Write-Host ""
    Write-Host "    [0] Sair" -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "  Opcao"

    switch ($choice) {
        "1" { Invoke-PermanentInstall }
        "2" { Invoke-Temporary }
        "3" { Invoke-Restore }
        default { return }
    }
}

Show-Banner

switch ($Mode) {
    "Permanent"    { Invoke-PermanentInstall }
    "Temporary"    { Invoke-Temporary }
    "PermanentRun" { Invoke-PermanentRun }
    "Restore"      { Invoke-Restore }
    default        { Show-Menu }
}
