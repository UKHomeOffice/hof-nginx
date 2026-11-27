const http = require('node:http');

const errorCodes = [403, 404, 429, 500, 501, 502, 503, 504];
const host = process.env.HOST;
const port = Number(process.env.PORT ?? 8080);

http.createServer((req, res) => {
  const match = /^\/status\/(403|404|429|500|501|502|503|504)$/.exec(req.url);
  if (match) {
    res.writeHead(Number(match[1]), { 'Content-Type': 'text/plain' });
    res.end(`Application error ${match[1]}\n`);
    return;
  }

  if (req.url !== '/') {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Application page not found\n');
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Error page test</title></head>
<body><h1>Error page test</h1>
<p>Follow a link to request an application error through the proxy.</p>
<ul>${errorCodes.map(code => `<li><a href="/status/${code}">HTTP ${code}</a></li>`).join('')}</ul>
</body></html>`);
}).listen(port, host, function () {
  console.log(`Error page test app listening on ${host || 'all interfaces'}:${this.address().port}`);
});
