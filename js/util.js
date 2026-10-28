// Escape text before putting it into HTML (stops injected markup).
function esc(value) {
    return String(value ?? "").replace(/[&<>""]/g, (c) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
}

function showMsg(el, text, ok) {
    el.textContent = text;
    el.className = "status " + (ok ? "ok" : "bad");
}

function friendlyError(error) {
    if (!error) return "";
    if (error.code === "23505") return "That code or name already exists.";
    if (error.code === "42501") return "You do not have permission to do that.";
    return error.message;
}
function fmtDateTime(iso) {
    return new Date(iso).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
}

//ISO (UTC) string -> value for a datetime-local input, in local time
function toLocalInput(iso) {
    const d = new Date(iso);
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}