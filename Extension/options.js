const $ = (id) => document.getElementById(id);
chrome.storage.sync.get(["token", "enabled"]).then(({ token = "", enabled = true }) => {
  $("token").value = token;
  $("enabled").checked = enabled;
});
$("save").onclick = async () => {
  await chrome.storage.sync.set({ token: $("token").value.trim(), enabled: $("enabled").checked });
  $("msg").textContent = "Saved";
};
