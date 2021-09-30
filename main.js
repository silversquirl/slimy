(function(window) {
	'use strict';

	const form = document.getElementById("params");
	const csv_btn = document.getElementById("csv");
	const status = document.getElementById("status");
	const result_list = document.getElementById("results");

	// Less-than operation for search results
	const resultsInOrder = (a, b) => {
		if (a.count != b.count) {
			return a.count > b.count;
		}

		const a_d2 = a.x*a.x + a.z*a.z;
		const b_d2 = b.x*b.x + b.z*b.z;
		if (a_d2 != b_d2) {
			return a_d2 < b_d2;
		}

		if (a.x != b.x) {
			return a.x < b.x;
		}
		if (a.z != b.z) {
			return a.z < b.z;
		}
		return false;
	};

	let world_seed;
	let results = [];
	const reportResult = (res) => {
		// Insert the result preserving sortedness
		var i = results.length;
		while (i > 0 && resultsInOrder(res, results[i-1])) i--;
		results.splice(i, 0, res);

		// Insert a DOM element at the same position
		const elem = document.createElement("li");
		elem.innerText = `(${res.x}, ${res.z}) ${res.count}`;
		if (i === result_list.length) {
			result_list.appendChild(elem);
		} else {
			result_list.insertBefore(elem, result_list.children[i]);
		}

		csv.style = "";
	}

	let threads = [];
	let active_count = 0;
	let resolve_threads;
	let threads_promise;
	const createThread = () => {
		const thread = {
			worker: new Worker("worker.js"),
			progress: 0,
		};

		thread.worker.onerror = e => {
			status.innerText = "Error spawning workers";
		};

		thread.worker.onmessage = e => {
			switch (e.data.type) {
			case "log": // Debugging
				console.log(e.data.msg);
				break;

			case "progress":
				thread.progress = e.data.progress;
				if (e.data.progress > 1) console.log(e.data.progress);
				let total = 0;
				for (const thr of threads) {
					total += thr.progress;
				}
				const percent = total * 100 / threads.length;
				status.innerText = `Searching... (${percent.toFixed(2)}%)`;
				break;

			case "result":
				reportResult(e.data);
				break;

			case "finish":
				active_count--;
				if (active_count === 0) {
					status.innerText = `Done in ${e.data.time}ms`;
					resolve_threads();
				}
				break;

			case "cancel":
				active_count--;
				if (active_count === 0) {
					resolve_threads();
				}
			}
		};

		return thread;
	};

	const thread_count = navigator.hardwareConcurrency;
	for (let i = 0; i < thread_count; i++) {
		threads.push(createThread());
	}

	window.submitSearch = params => {
		results = [];
		while (result_list.firstChild) {
			result_list.removeChild(result_list.firstChild)
		}
		world_seed = params.seed;
		csv.style = "display: none;";

		active_count = threads.length;
		threads_promise = new Promise(resolve => resolve_threads = resolve);
		for (let thread_idx = 0; thread_idx < threads.length; thread_idx++) {
			const thread_width = (params.z1 - params.z0) / threads.length;
			const z0 = params.z0 + thread_idx * thread_width;
			const z1 = thread_idx === threads.length - 1 ? params.z1 : z0 + thread_width;

			threads[thread_idx].worker.postMessage({
				seed: params.seed,
				threshold: params.threshold,

				x0: params.x0,
				x1: params.x1,
				z0: z0,
				z1: z1,
			});
		}
	};

	form.addEventListener("submit", async ev => {
		ev.preventDefault();

		if (active_count != 0) {
			for (let thr of threads) {
				thr.worker.postMessage("cancel");
			}
			await threads_promise;
		}

		const seed = BigInt(form.elements.seed.value);
		const threshold = form.elements.threshold.value | 0;
		const range = form.elements.range.value | 0;

		submitSearch({
			seed: seed,
			threshold: threshold,

			x0: -range,
			x1: range,
			z0: -range,
			z1: range,
		});
	});

	window.genCsv = () => {
		let csv = [];
		csv.push("X (chunk coord),Z (chunk coord),Count");
		for (let res of results) {
			csv.push(`${res.x},${res.z},${res.count}`);
		}
		return csv.join("\n") + "\n";
	};

	csv_btn.addEventListener("click", ev => {
		const link = document.createElement("a");
		link.href = "data:text/csv;base64," + btoa(genCsv());
		link.download = `slimy${world_seed}.csv`;
		link.click();
	});
})(window);
