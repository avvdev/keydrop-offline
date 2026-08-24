"use strict";

const downloadAndSelect = document.querySelector("#download-and-select");
const encryptedFileInput = document.querySelector("#encrypted-file");
const encryptedFileInfo = document.querySelector("#file-info");
const pageStatus = document.querySelector("#status");
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;
const activeKey = "keydrop-active-v1";
let activeDrop = null;

downloadAndSelect.addEventListener("click", async () => {
  encryptedFileInfo.textContent = "Скачиваю и выбираю файл…";
  try {
    const response = await fetch(downloadAndSelect.href);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const file = new File(
      [await response.blob()],
      downloadAndSelect.download,
      { type: "application/octet-stream" },
    );
    const transfer = new DataTransfer();
    transfer.items.add(file);
    encryptedFileInput.files = transfer.files;
    encryptedFileInput.dispatchEvent(new Event("change", { bubbles: true }));
    pageStatus.textContent = "Файл скачан и уже выбран. Проводник Android не нужен.";
    pageStatus.dataset.error = "false";
  } catch (error) {
    pageStatus.textContent = "Скачивание началось, но автоматически выбрать файл не удалось. Выбери его вручную.";
    pageStatus.dataset.error = "true";
  }
});

const productionReady = startProduction();

async function startProduction() {
  const fragment = location.hash.slice(1);
  let saved = readActiveDrop();
  if (tokenPattern.test(fragment)) {
    const replacement = `${location.pathname}${location.search || ""}`;
    history.replaceState(null, "", replacement);
    saved = { token: fragment, lease: randomToken(), phase: "fetch" };
    writeActiveDrop(saved);
  }
  if (!saved || !tokenPattern.test(saved.token) || !tokenPattern.test(saved.lease)) return;

  activeDrop = saved;
  setProductionMode();
  if (saved.phase === "ack") {
    pageStatus.textContent = "Завершаю одноразовую передачу…";
    await finishDrop(saved);
    return;
  }
  observeSuccessfulDecrypt();
  encryptedFileInfo.textContent = "Получаю зашифрованный файл…";
  try {
    const claim = await dropRequest("/api/v1/drop/claim", "POST", saved);
    if (!claim.ok) {
      if (claim.status === 410) clearActiveDrop();
      throw new Error(claim.status === 410 ? "Ссылка уже использована или истекла" : "Не удалось получить файл");
    }
    const response = await dropRequest("/api/v1/drop", "GET", saved);
    if (!response.ok) {
      if (response.status === 410) clearActiveDrop();
      throw new Error(response.status === 410 ? "Ссылка уже использована или истекла" : "Не удалось получить файл");
    }
    const size = Number(response.headers.get("content-length"));
    if (!Number.isSafeInteger(size) || size < 1 || size > 16 * 1024 * 1024) throw new Error("Недопустимый размер файла");
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength !== size) throw new Error("Файл получен не полностью");
    const expected = response.headers.get("x-keydrop-sha256") || "";
    if (expected !== await sha256Hex(bytes)) throw new Error("Контрольная сумма файла не совпала");
    selectEncryptedFile(new File([bytes], "delivery.enc", { type: "application/octet-stream" }));
    pageStatus.textContent = "Файл получен и выбран. Введи пароль доставки.";
    pageStatus.dataset.error = "false";
  } catch (error) {
    pageStatus.textContent = error.message || "Не удалось получить файл";
    pageStatus.dataset.error = "true";
  }
}

function setProductionMode() {
  document.querySelector("h1").textContent = "Защищённая доставка";
  document.querySelector("#intro").textContent = "Зашифрованный файл загружается один раз и расшифровывается только на этом устройстве.";
  downloadAndSelect.hidden = true;
  document.querySelector("#download-help").hidden = true;
  document.querySelector("#fill-test-password").hidden = true;
}

function selectEncryptedFile(file) {
  const transfer = new DataTransfer();
  transfer.items.add(file);
  encryptedFileInput.files = transfer.files;
  encryptedFileInput.dispatchEvent(new Event("change", { bubbles: true }));
}

function observeSuccessfulDecrypt() {
  const observer = new MutationObserver(() => {
    if (pageStatus.textContent !== "Готово. Файл расшифрован на этом устройстве." || !activeDrop) return;
    const completed = activeDrop;
    completed.phase = "ack";
    writeActiveDrop(completed);
    observer.disconnect();
    finishDrop(completed);
  });
  observer.observe(pageStatus, { childList: true });
}

async function finishDrop(drop) {
  try {
    const response = await dropRequest("/api/v1/drop/ack", "POST", drop);
    if (response.ok) {
      clearActiveDrop();
      activeDrop = null;
      pageStatus.textContent = "Готово. Серверная копия удалена.";
      return;
    }
    if (response.status === 410) {
      clearActiveDrop();
      activeDrop = null;
      pageStatus.textContent = "Файл расшифрован. Ссылка уже закрыта; немедленное удаление серверной копии не подтверждено.";
      pageStatus.dataset.error = "true";
      return;
    }
  } catch {}
  pageStatus.textContent = "Файл расшифрован. Удаление серверной копии повторится при следующем открытии.";
  pageStatus.dataset.error = "true";
}

function dropRequest(path, method, drop) {
  return fetch(path, {
    method,
    headers: {
      Authorization: `Keydrop ${drop.token}`,
      "X-Keydrop-Lease": drop.lease,
    },
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
    referrerPolicy: "no-referrer",
    keepalive: path.endsWith("/ack"),
  });
}

function readActiveDrop() {
  try { return JSON.parse(sessionStorage.getItem(activeKey)); } catch { return null; }
}

function writeActiveDrop(drop) {
  try { sessionStorage.setItem(activeKey, JSON.stringify(drop)); } catch {}
}

function clearActiveDrop() {
  try { sessionStorage.removeItem(activeKey); } catch {}
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256Hex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
