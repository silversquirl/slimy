(function() {
	'use strict';

	const status = document.getElementById("status");
	const results = document.getElementById("results");

	const worker = new Worker("worker.js");
	worker.onerror = e => {
		console.log(e);
		status.innerText = "Error! :(";
	};
	worker.onmessage = e => {
		switch (e.data.type) {
		case "log": // Debugging
			console.log(e.data.msg);
			break;

		case "progress":
			const percent = e.data.progress * 100;
			status.innerText = `Searching... (${percent.toFixed(2)}%)`;
			break;

		case "result":
			const elem = document.createElement("li");
			elem.innerText = `(${e.data.x}, ${e.data.y}) ${e.data.count}`;
			results.appendChild(elem);
			break;

		case "finish":
		    status.innerText = `Done in ${e.data.time}ms`;
		    break;
		}
	};

	worker.postMessage({
		seed: 1n,
		range: 1000,
		threshold: 41,
	});
})();
