// 填入你們自己 Supabase 專案的資料（後台 → Project Settings → API）
// anon key 本來就是公開用的金鑰，放在這裡沒有關係；
// 資料靠資料庫裡的函式核對成員身分來保護。
window.SPACE_CONFIG = {
  SUPABASE_URL: "https://mfxxtiyivtcuhohtpqgs.supabase.co",       
  SUPABASE_ANON_KEY: "sb_publishable_tymrFI7PiAIxB7R2mRUjFw_jnmuQ0-f"   
  // 通話：大多數網路用預設設定就連得上。若有人在公司、學校或某些行動網路下一直「連不上」，
  // 可以申請一組 TURN 伺服器（例如 Cloudflare Calls、metered.ca 的免費額度），把下面這段取消註解填進去。
  // ICE_SERVERS: [
  //   { urls: "stun:stun.l.google.com:19302" },
  //   { urls: "turn:你的TURN伺服器:3478", username: "帳號", credential: "密碼" }
  // ]
};
