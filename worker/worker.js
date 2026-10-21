// Cloudflare Worker: Reels Pro upload endpoint.
// App ke andar R2 ki secret keys nahi hoti - app sirf is Worker ko PUT karta hai.
//
// Deploy:
//   npm i -g wrangler && wrangler login
//   wrangler r2 bucket create my-reels-bucket      (agar bucket nahi hai)
//   wrangler secret put APP_TOKEN                   (koi lamba random token)
//   wrangler deploy
// Phir main.dart me: kUploadBase = 'https://reels-upload.<tumhara>.workers.dev'
//                    kUploadToken = <wahi APP_TOKEN>
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== 'PUT' || !url.pathname.startsWith('/upload/')) {
      return new Response('Not found', { status: 404 });
    }
    if (env.APP_TOKEN && request.headers.get('X-App-Token') !== env.APP_TOKEN) {
      return new Response('Unauthorized', { status: 401 });
    }

    const key = decodeURIComponent(url.pathname.slice('/upload/'.length));
    if (!/^reel_\d{10,16}\.mp4$/.test(key)) {
      return new Response('Bad file name', { status: 400 });
    }

    const len = Number(request.headers.get('content-length') || 0);
    if (!len || len > 100 * 1024 * 1024) {
      return new Response('File missing or larger than 100 MB', { status: 413 });
    }

    await env.BUCKET.put(key, request.body, {
      httpMetadata: { contentType: 'video/mp4' },
    });

    return new Response(JSON.stringify({ url: `${env.PUBLIC_BASE}/${key}` }), {
      headers: { 'Content-Type': 'application/json' },
    });
  },
};
