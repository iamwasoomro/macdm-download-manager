import http.client, json, socket
ORIGIN = 'chrome-extension://' + 'a' * 32

def request(path='/add', origin=ORIGIN, payload=None, method='POST'):
    connection = http.client.HTTPConnection('127.0.0.1', 17212, timeout=5)
    headers = {'Content-Type': 'application/json'}
    if origin is not None: headers['Origin'] = origin
    body = json.dumps(payload or {'url': 'https://example.test/file'})
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    result = response.status, response.getheader('Access-Control-Allow-Origin')
    response.read(); connection.close()
    return result

assert request()[0] == 200
assert request(origin='https://evil.example')[0] == 403
assert request(origin='null')[0] == 403
assert request(path='/add-unknown')[0] == 404
assert request(payload={'url': 'file:///etc/passwd'})[0] == 400
assert request(payload={'url': 'https://example.test', 'cookies': 'a\r\nb'})[0] == 400
assert request(method='GET')[0] == 405
assert request(method='OPTIONS') == (204, ORIGIN)
assert request(origin=None)[0] == 200
with socket.create_connection(('127.0.0.1', 17212), timeout=5) as connection:
    connection.sendall(b'POST /add HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx')
    assert b'400 Bad Request' in connection.recv(4096)
print('PASS: seamless bridge connection, origins, routes, preflight, URL/header validation, duplicate headers')
