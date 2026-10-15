//use ONLY the project URL and the publishable (anon) key here.
//Never put the service-rolekey in this file.

const SUPABASE_URL = "https://mruvjbwanewgsajwyfjk.supabase.co";
const SUPABASE_KEY = "sb_publishable_NdXypON8hi_BzT8QMx2cvw_G_ke_j_C";

const supabaseClient= window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

//Simple connectivity checkagainst Auth's health endpoint
async function checkSupabaseConnection() {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/health`, {
        headers: {apikey: SUPABASE_KEY},
    });
    if (!res.ok) throw new Error('Supabase responded with status ${res.status}');
    return true;
}