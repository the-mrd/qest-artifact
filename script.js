function copyCommand(button) {
  const command = button.getAttribute("data-command") || "";
  navigator.clipboard.writeText(command).then(
    () => {
      const original = button.textContent;
      button.textContent = "Copied";
      button.classList.add("copied");
      window.setTimeout(() => {
        button.textContent = original;
        button.classList.remove("copied");
      }, 1600);
    },
    () => {
      button.textContent = "Select";
    }
  );
}

window.copyCommand = copyCommand;
