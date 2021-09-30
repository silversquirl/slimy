(function() {
	'use strict';

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

	let results = [];
	const reportResult = (res) => {
		// Insert the result preserving sortedness
		var i = results.length;
		while (i > 0 && resultsInOrder(res, results[i-1])) i--;
		results.splice(i, 0, res);

		// Insert a DOM element at the same position
		const elem = document.createElement("li");
		elem.innerText = `(${res.x}, ${res.y}) ${res.count}`;
		if (i == result_list.length) {
			result_list.appendChild(elem);
		} else {
			result_list.insertBefore(elem, result_list.children[i]);
		}
	}

	let threads = [];
	let active_count = 0;
	const createThread = () => {
		const thread = {
			worker: new Worker("worker.js"),
			progress: 0,
		};

		thread.worker.onerror = e => {
			console.log(e);
			status.innerText = "Error! :(";
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
				if (active_count == 0) {
				    status.innerText = `Done in ${e.data.time}ms`;
				}
			    break;
			}
		};

		return thread;
	};

	const thread_count = navigator.hardwareConcurrency;
	for (let i = 0; i < thread_count; i++) {
		threads.push(createThread());
	}

	const submitSearch = params => {
		if (active_count != 0) {
			console.log("Search alread in progress");
			return;
		}

		active_count += threads.length;
		for (let thread_idx = 0; thread_idx < threads.length; thread_idx++) {
            const thread_width = (params.z1 - params.z0) / threads.length;
            const z0 = params.z0 + thread_idx * thread_width;
            const z1 = thread_idx == threads.length - 1 ? params.z1 : z0 + thread_width;

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

	submitSearch({
		seed: 1n,
		threshold: 41,

		x0: -1000,
		x1: 1000,
		z0: -1000,
		z1: 1000,
	});
})();
