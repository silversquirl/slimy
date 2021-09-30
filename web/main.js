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

	const cpu_searcher = {
		threads: [],
		active_count: 0,
		resolve_threads: null,
		threads_promise: null,

		createThread() {
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
					const percent = this.progress() * 100;
					status.innerText = `Searching... (${percent.toFixed(2)}%)`;
					break;

				case "result":
					reportResult(e.data);
					break;

				case "finish":
					this.active_count--;
					if (this.active_count === 0) {
						status.innerText = `Done in ${e.data.time}ms`;
						this.resolve_threads();
					}
					break;

				case "cancel":
					this.active_count--;
					if (this.active_count === 0) {
						this.resolve_threads();
					}
				}
			};

			return thread;
		},

		init() {
			const thread_count = navigator.hardwareConcurrency;
			for (let i = 0; i < thread_count; i++) {
				this.threads.push(this.createThread());
			}
		},
		ensure_init() {
			if (this.threads.length == 0) {
				this.init();
			}
		},

		active() {
			return this.active_count != 0;
		},
		progress() {
			let total = 0;
			for (const thr of this.threads) {
				total += thr.progress;
			}
			return total / this.threads.length
		},

		async cancel() {
			for (let thr of this.threads) {
				thr.worker.postMessage("cancel");
			}
			await this.threads_promise;
		},

		submit(params) {
			this.ensure_init();
			this.active_count = this.threads.length;
			this.threads_promise = new Promise(resolve => this.resolve_threads = resolve);
			for (let thread_idx = 0; thread_idx < this.threads.length; thread_idx++) {
				const thread_width = (params.z1 - params.z0) / this.threads.length;
				const z0 = params.z0 + thread_idx * thread_width;
				const z1 = thread_idx === this.threads.length - 1 ? params.z1 : z0 + thread_width;

				this.threads[thread_idx].worker.postMessage({
					seed: params.seed,
					threshold: params.threshold,

					x0: params.x0,
					x1: params.x1,
					z0: z0,
					z1: z1,
				});
			}
		},
	};

	let searcher = cpu_searcher;

	window.submitSearch = params => {
		results = [];
		while (result_list.firstChild) {
			result_list.removeChild(result_list.firstChild)
		}
		world_seed = params.seed;
		csv.style = "display: none;";

		if (searcher.active()) {
			searcher.cancel();
		}
		searcher.submit(params);
	};

	form.addEventListener("submit", async ev => {
		ev.preventDefault();

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
