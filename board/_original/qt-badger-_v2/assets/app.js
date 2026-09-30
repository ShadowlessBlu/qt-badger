async function deconstructSchedule() {
    const input = document.getElementById("scheduleInput");
    const text = input.value.trim();
    if (!text) {
        alert("Please enter some schedule text first.");
        return;
    }
    showToast("Processing with LLM...");
    try {
        const response = await fetch('/api/organize', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text })
        });
        const result = await response.json();
        if (result.status === "success") {
            showToast(`Extracted ${result.added.length} reminder(s)!`);
            input.value = "";
            // Refresh task list via serial if connected
            if (writer) sendCommand("LIST");
        } else {
            alert("Error: " + (result.message || "Unknown error"));
        }
    } catch (e) {
        alert("Failed to reach backend: " + e.message);
    }
}