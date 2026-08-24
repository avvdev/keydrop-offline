"use strict";

const downloadAndSelect = document.querySelector("#download-and-select");
const encryptedFileInput = document.querySelector("#encrypted-file");
const encryptedFileInfo = document.querySelector("#file-info");
const pageStatus = document.querySelector("#status");

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
