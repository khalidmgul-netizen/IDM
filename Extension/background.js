const ENDPOINT = "http://127.0.0.1:6811/add";

async function sendToFetchly(url, extra = {}) {
  const { token } = await chrome.storage.sync.get("token");
  if (!token) return false;
  let cookie = "";
  try {
    const cookies = await chrome.cookies.getAll({ url });
    cookie = cookies.map(c => `${c.name}=${c.value}`).join("; ");
  } catch (_) {}
  try {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Fetchly-Token": token },
      body: JSON.stringify({ url, cookie, userAgent: navigator.userAgent, ...extra })
    });
    return res.ok;
  } catch (_) {
    return false; // app not running -> let the browser download normally
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const { enabled = true } = await chrome.storage.sync.get("enabled");
  const url = item.finalUrl || item.url;
  if (!enabled || !/^https?:/i.test(url)) return;
  const ok = await sendToFetchly(url, {
    referer: item.referrer || "",
    filename: item.filename ? item.filename.split(/[\\/]/).pop() : ""
  });
  if (ok) {
    chrome.downloads.cancel(item.id, () => chrome.downloads.erase({ id: item.id }));
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "fetchly-link", title: "Download with Fetchly", contexts: ["link"] });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === "fetchly-link" && info.linkUrl) {
    sendToFetchly(info.linkUrl, { referer: info.pageUrl || "" });
  }
});
