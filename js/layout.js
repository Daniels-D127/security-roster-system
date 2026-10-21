const IN_PAGES = location.pathname.includes("/pages/");
const BASE = IN_PAGES ? "../":"";

const NAV_ITEMS = [
    ["Dashboard", BASE + "dashboard.html"],
    ["Guards", BASE + "pages/guards.html"],
    ["Sites", BASE + "pages/sites.html"],
    ["Rosters", BASE + "pages/rosters.html"],
    ["Attendance", BASE + "pages/attendance.html"],
    ["Patrols", BASE + "pages/patrols.html"],
    ["Incidents", BASE + "pages/incidents.html"],
    ["Reports", BASE + "pages/reports.html"],
];

function renderNav () {
    const current = location.pathname.split("/").pop();
    const links = NAV_ITEMS.map(([label, href]) => {
        const active = href.split("/").pop() === current ? "active":"";
        return`<a href="${href}" class="${active}">${label}</a>`;
    }).join("");

    document.body.insertAdjacentHTML(
        "afterbegin",
        `<header class= "topbar">
        <strong>Security Roster</strong>
        <a href="${BASE}login.html">log out</a>
        </header>
        <nav class="nav">${links}</nav>`
    );
}

renderNav();