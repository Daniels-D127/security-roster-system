document.body.style.visibility = "hidden";

const IN_PAGES = location.pathname.includes("/pages/");
const BASE = IN_PAGES ? "../":"";
const ALL = ["admin", "supervisor", "guard"];
const STAFF = ["admin", "supervisor"];

// [label, link, roles that can see it] (UI convenience only; the database enforses access)
const NAV_ITEMS = [
    ["Dashboard", BASE + "dashboard.html", ALL],
    ["Guards", BASE + "pages/guards.html", STAFF],
    ["Sites", BASE + "pages/sites.html", STAFF],
    ["Rosters", BASE + "pages/rosters.html", ALL],
    ["Attendance", BASE + "pages/attendance.html", ALL],
    ["Patrols", BASE + "pages/patrols.html", ALL],
    ["Incidents", BASE + "pages/incidents.html", ALL],
    ["Reports", BASE + "pages/reports.html", STAFF],
];

function currentFile() {
    return location.pathname.split("/").pop() || "index.html";
}

function renderNav(profile) {
    const current = currentFile();
    const links = NAV_ITEMS
    .filter(([,, roles]) => roles.includes(profile.role))
    .map(([label, href]) => {
        const active = href.split("/").pop() === current ? "active":"";
        return `<a href="${href}" class="${active}">${label}</a>`;
    }).join("");

    document.body.insertAdjacentHTML(
        "afterbegin",
        `<header class= "topbar">
        <strong>Security Roster</strong>
        <span><span class="who" id="whoami"></span><a href="#" id="logoutLink">Log out</a></span>
        </header>
        <nav class="nav">${links}</nav>`
    );

    document.getElementById("whoami").textContent = `${profile.full_name} (${profile.role})`;
    document.getElementById("logoutLink").addEventListener("click",async (e) => {
        e.preventDefault();
        await supabaseClient.auth.signOut();
        location.href = BASE + "login.html";
    });
}

async function initPage() {
    const { data: { session}} = await supabaseClient.auth.getSession();
    if (!session) {
        location.href = BASE + "login.html";
        return;
    }

const { data: profile, error } = await supabaseClient
.from("profiles")
.select("full_name, role, active")
.eq("id", session.user.id)
.single();

if (error || !profile || !profile.active) {
    await supabaseClient.auth.signOut();
    location.href = BASE + "login.html?error=noprofile";
    return;
}

const here = NAV_ITEMS.find(([, href]) => href.split("/").pop() === currentFile());
if (here && !here[2].includes(profile.role)) {
    location.href = BASE + "dashboard.html";
    return;
}

renderNav(profile);
document.body.style.visibility = "visible";
return profile;
}

const pageReady = initPage().catch((err) => {
    document.body.style.visibility = "visible";
    const pre = document.createElement("pre");
    pre.style.cssText = "color:red;padding:1rem";
    pre.textContent = "Error: " + err.message;
    document.body.prepend(pre);
    return null;
});