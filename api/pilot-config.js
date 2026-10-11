// Only public Supabase credentials. Never use a service-role/secret key here.
module.exports = function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if(req.method !== 'GET') return res.status(405).json({error:'Method not allowed'});
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if(!url || !key) return res.status(503).json({error:'Pilot setup pending: database and authentication are not connected.'});
  let valid=false;
  if(key.startsWith('sb_publishable_')) valid=true;
  else { try {valid=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString()).role==='anon';} catch {} }
  if(!valid) return res.status(503).json({error:'Invalid public configuration. A publishable or anon key is required.'});
  try {const u=new URL(url);if(u.protocol!=='https:'||!u.hostname.endsWith('.supabase.co')||u.username||u.password)throw new Error();}catch{return res.status(503).json({error:'Invalid Supabase project URL.'});}
  return res.status(200).json({url, key});
};
