"""Optional standalone build using the Vitis 2025.2 Python CLI.

Run with ``vitis -s build/scripts/baremetal/build_application.py``.
This is separate from the final Linux runtime. Never uses an older local BSP.
"""
from pathlib import Path
import os
import shutil


def main():
    import vitis
    root = Path(__file__).resolve().parents[3]
    workspace = Path(os.environ.get("NPU_BAREMETAL_WORKSPACE", str(root / "build/work/vitis"))).resolve()
    xsa = Path(os.environ.get("NPU_XSA", str(root / "board/hardware/npu100.xsa"))).resolve()
    if not xsa.is_file():
        raise FileNotFoundError(xsa)
    if workspace.exists() and any(workspace.iterdir()):
        raise RuntimeError(f"Refusing to reuse a nonempty workspace: {workspace}")
    workspace.mkdir(parents=True, exist_ok=True)
    client = vitis.create_client()
    try:
        client.set_workspace(str(workspace))
        platform = client.create_platform_component(
            name="npu100_platform", hw_design=str(xsa), os="standalone",
            cpu="ps7_cortexa9_0", domain_name="standalone_a9_0",
            generate_dtb=False, compiler="gcc")
        domain = platform.get_domain("standalone_a9_0")
        domain.set_lib("xilffs")
        domain.set_config("os", "standalone_stdout", "ps7_uart_0")
        domain.set_config("os", "standalone_stdin", "ps7_uart_0")
        platform.build()
        xpfm = client.find_platform_in_repos("npu100_platform")
        app = client.create_app_component(
            name="npu100_app", platform=xpfm, domain="standalone_a9_0",
            template="empty_application")
        # Preserve the packaged CMake, linker and sibling runtime layout.
        shutil.copytree(root / "src/software/app/src", workspace / "npu100_app/src", dirs_exist_ok=True)
        shutil.copytree(root / "src/software/runtime/baremetal", workspace / "runtime/baremetal", dirs_exist_ok=True)
        app.build()
        for elf in (workspace / "npu100_app").rglob("*.elf"):
            print(f"BUILT_ELF={elf}")
    finally:
        vitis.dispose()


if __name__ == "__main__":
    main()
