function solve() {
    challenge = document.getElementById("challenge").textContent;
    entries = challenge.split(".");

    salt = Uint8Array.fromBase64(entries[0]);
    target_hash = Uint8Array.fromBase64(entries[1]);

    hash_input = new Uint8Array(salt.length + 4);
    hash_input.set(salt);

    counter_view = new DataView(hash_input.buffer, salt.length, 4);

    counter_view.setUint32(0, 0);

    hash = new Uint8Array(32);

    blake(32).update(hash_input).digest(hash)

    while (!equal(hash, target_hash)) {
        counter_view.setUint32(0, counter_view.getUint32(0) + 1);

        blake(32).update(hash_input).digest(hash);
    }

    answer = entries[0] + "." + counter_view.getUint32(0) + "." + entries[2];

    var http = new XMLHttpRequest();
    http.open('POST', '/pow/submit', true);
    http.withCredentials = true;

    http.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    http.onreadystatechange = function() {
        document.getElementById("challenge").style = "";
        document.getElementById("challenge").innerText = "Success!";

        setTimeout(function() { 
            urlParams = new URLSearchParams(document.location.search);
            if (urlParams.has("redirect")) {
                document.location.pathname = urlParams.get("redirect");
            } else {
                document.location.pathname = "/";
            }
        }, 1000);
    }
    http.send("answer=" + encodeURIComponent(answer));
}

function equal(a, b) {
    if (a.length !== b.length) return false;
    
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) {
            return false;
        }
    }

    return true;
}


document.getElementById("solve").onclick = "solve();";
