// SPDX-License-Identifier: GPL-2.0-only
/* npu100 fixed-address Zynq-7020 interface, Linux 6.12.
 * Bootloader must load matching PL/FCLK/reset before ANY MMIO operation.
 * Probe does not access PL; a missing AXI slave cannot be made safe by a
 * software read timeout. Never reload PL or remove this DT device while open.
 * Close never cancels, releases, resets or reuses accepted hardware ownership.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of_reserved_mem.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/uaccess.h>
#include <linux/capability.h>
#include <linux/compat.h>
#include <linux/dma-mapping.h>
#include <linux/gpio/consumer.h>
#include <linux/mutex.h>
#include <linux/kref.h>
#include <linux/slab.h>
#include <linux/clk.h>
#include "unified_npu_uapi.h"
#define NPU_CLOCK_COUNT 2
#define NPU_CLOCK_HZ 100000000UL
#define NPU_CLOCK_ROUNDING_HZ 1UL

struct npu_window { u32 phys, size; };
static const struct npu_window windows[NPU_REGIONS] = {
    {0x43c10000, 0x8000}, {0x43c18000, 0x8000},
    {0x12000000, 0x02000000}, {0x14000000, 0x06000000},
    {0x1a000000, 0x01000000}, {0x1b000000, 0x01000000},
    {0x41200000, 0x10000}, {0x41210000, 0x10000}
};
static const unsigned int mmio_regions[] = {NPU_FRONTEND, NPU_GRAPH, NPU_CONTROL, NPU_STATS};
struct npu_device {
    struct miscdevice misc;
    struct mutex lock;
    struct kref refs;
    void __iomem *regs[NPU_REGIONS];
    struct gpio_desc *resnet_key, *neu_key;
    /* devm_clk_bulk_get retains this array until devres cleanup; keep its
     * storage devm-owned rather than inside the separately kref-owned n. */
    struct clk_bulk_data *clocks;
    bool owner, dead, orphaned;
};
struct npu_file {
    struct npu_device *n;
    bool verified, lease, task;
    u32 lease_frame, lease_generation, task_id, task_frame, task_generation;
};
static bool ddr_region(u32 region)
{
    return region >= NPU_RAW && region <= NPU_COCO;
}
static u32 fr(struct npu_device *n, u32 off) { return readl(n->regs[NPU_FRONTEND] + off); }
static u32 gr(struct npu_device *n, u32 off) { return readl(n->regs[NPU_GRAPH] + off); }
static bool graph_quiet(struct npu_device *n)
{
    return !(gr(n, 0x0c) & 0xbu) && !(gr(n, 4) & 0xbu) && !gr(n, 0x78);
}
static int verify_pl(struct npu_file *f)
{
    struct npu_device *n = f->n;
    u32 hz;
    if (f->verified) return 0;
    /* All first reads require the boot-time PL-ready contract, not probing
     * unconfigured fabric. INFO alone can be used before that contract. */
    if (fr(n, 0) != 0x50525031 || fr(n, 0x5c) != 8 ||
        fr(n, 0x88) != 0x43414d32 || fr(n, 0x94) != 0x4c495631 ||
        fr(n, 0xac) != 0x4f564c33 || fr(n, 0x1a4) != 0x26110104 ||
        fr(n, 0x1a8) != 0x00080307 || fr(n, 0x340) != 0x4b455931 ||
        gr(n, 0) != 0x4e475031 || gr(n, 0x88) != 2 || gr(n, 0xdc) != 0xau)
        return -EPROTO;
    hz = gr(n, 0xd8);
    if (hz != 100000000) return -EPROTO;
    f->verified = true;
    return 0;
}
static bool allowed_read(u32 region, u32 off)
{
    if (off & 3) return false;
    if (region == NPU_CONTROL || region == NPU_STATS)
        return off == 0 || off == 4 || off == 8 || off == 12;
    if (region == NPU_GRAPH) {
        switch (off) {
        case 0x00: case 0x04: case 0x08: case 0x0c:
        case 0x10: case 0x14: case 0x18: case 0x1c:
        case 0x20: case 0x24: case 0x28: case 0x2c:
        case 0x30: case 0x34: case 0x38: case 0x3c:
        case 0x40: case 0x44: case 0x48: case 0x4c:
        case 0x50: case 0x54: case 0x58: case 0x60:
        case 0x64: case 0x68: case 0x6c: case 0x70:
        case 0x74: case 0x78: case 0x7c: case 0x80:
        case 0x88: case 0x8c: case 0x90: case 0x94:
        case 0x98: case 0x9c: case 0xa0: case 0xa4:
        case 0xa8: case 0xac: case 0xb0: case 0xb4:
        case 0xb8: case 0xbc: case 0xc0: case 0xc4:
        case 0xc8: case 0xcc: case 0xd0: case 0xd4: case 0xd8: case 0xdc:
        case 0xfc: /* DIA feature bits select the available timing source. */
            return true;
        default: return false;
        }
    }
    if (region != NPU_FRONTEND) return false;
    switch (off) {
    case 0x00: case 0x04: case 0x18: case 0x1c: case 0x20: case 0x24:
    case 0x30: case 0x38: case 0x40: case 0x44: case 0x48: case 0x4c:
    case 0x50: case 0x54: case 0x58: case 0x5c: case 0x60: case 0x64:
    case 0x6c: case 0x70: case 0x80: case 0x84: case 0x88: case 0x8c:
    case 0x94: case 0x98: case 0x9c: case 0xa0: case 0xa4: case 0xa8:
    case 0xac: case 0xb0: case 0xb4: case 0xb8: case 0xbc: case 0xc0:
    case 0xc4: case 0xc8: case 0x190: case 0x194: case 0x198: case 0x19c:
    case 0x1a0: case 0x1a4: case 0x1a8: case 0x340: case 0x344: return true;
    default: return false;
    }
}
static bool valid_bcd(u32 value, unsigned int digits)
{
    unsigned int i;
    for (i = 0; i < digits; ++i, value >>= 4) if ((value & 15u) > 9u) return false;
    return !value;
}
static bool allowed_write(u32 region, u32 off, u32 value)
{
    if (off & 3) return false;
    if (region == NPU_CONTROL) {
        if (off == 0) return !(value & ~7u);
        if (off == 4) return value == 0;
        if (off == 12) return value == ~0u;
        return false;
    }
    if (region == NPU_STATS) return (off == 4 || off == 12) && value == ~0u;
    if (region == NPU_GRAPH) {
        switch (off) {
        case 0x04: return value == 1 || value == 2 || value == 4 || value == 8;
        case 0x08: return value <= 1;
        case 0x10: return value == 0x14000000 || value == 0x18000000 || value == 0x1b000000;
        case 0x18: return value == 0x1a000000;
        case 0x14: return value > 0 && value <= 0x02000000;
        case 0x1c: return value > 0 && value <= 0x007c0000;
        case 0x20: return value >= 0x14000000 && value < 0x1c000000 && !(value & 4095);
        case 0x24: return value > 0 && value <= 0x100000 && !(value & 4095);
        case 0x28: case 0x2c: return true;
        case 0x60: case 0x7c: return value >= 0x1a000000 && value < 0x1a7c0000;
        case 0x64: case 0x80: return value > 0 && value <= 0x007c0000;
        case 0x68: return value >= 1 && value <= 4;
        default: return false;
        }
    }
    if (region != NPU_FRONTEND) return false;
    switch (off) {
    case 0x04: return !(value & ~0x3du);
    case 0x08: case 0x0c: case 0x120: return value == 1;
    case 0x90: return value == 1 || value == 2 || value == 3 || value == 16;
    case 0x10: case 0x14: case 0x180: case 0x184: return true;
    case 0x188: return !(value & ~0x7f07u) && ((value >> 8) <= 100 || (value >> 8) == 127);
    case 0x18c: return !(value & ~0x1fu) && (value & 15) <= 8;
    case 0x190: case 0x198: return valid_bcd(value, 5);
    case 0x194: return value == 1 || value == 3 || value == 4;
    case 0x19c: return valid_bcd(value, 4);
    case 0x1a0: return value <= 3;
    default: return off >= 0x200 && off <= 0x278 && ((off - 0x200) & 15) <= 8;
    }
}
static bool terminal_owned(struct npu_file *f)
{
    struct npu_device *n = f->n;
    return f->task && !(gr(n, 0x0c) & 1) && (gr(n, 0x0c) & 2) && gr(n, 0x78) &&
           gr(n, 0x38) == f->task_id && gr(n, 0x40) == f->task_frame &&
           gr(n, 0x44) == f->task_generation;
}
static int guard_write(struct npu_file *f, u32 region, u32 off, u32 value)
{
    struct npu_device *n = f->n;
    if (n->orphaned) return -EOWNERDEAD;
    if (region == NPU_CONTROL && off == 0 && (f->task || f->lease)) return -EBUSY;
    if (region == NPU_GRAPH) {
        if (off == 4 && value == 1) {
            if (f->task || !graph_quiet(n) || (gr(n, 8) & 7) != 7) return -EBUSY;
        } else if (off == 4 && value == 2) {
            if (!f->task) return -EPERM;
        } else if (off == 4 && value == 4) {
            if (!terminal_owned(f)) return -EPERM;
        } else if (f->task || !graph_quiet(n)) return -EBUSY;
    }
    if (region == NPU_FRONTEND) {
        if (off == 8 && (f->lease || fr(n, 0x40))) return -EBUSY;
        if (off == 0xc || off == 0x120) {
            if (f->task || !graph_quiet(n)) return -EBUSY;
            if (!f->lease || !fr(n, 0x40) || fr(n, 0x48) != f->lease_frame ||
                fr(n, 0x4c) != f->lease_generation) return -EPERM;
        }
    }
    return 0;
}
static void npu_free(struct kref *ref)
{
    kfree(container_of(ref, struct npu_device, refs));
}
static int npu_open(struct inode *inode, struct file *file)
{
    struct npu_device *n = container_of(file->private_data, struct npu_device, misc);
    struct npu_file *f;
    int ret = 0;
    if (!capable(CAP_SYS_RAWIO)) return -EPERM;
    f = kzalloc(sizeof(*f), GFP_KERNEL);
    if (!f) return -ENOMEM;
    mutex_lock(&n->lock);
    if (n->dead) ret = -ENODEV;
    else if (n->owner) ret = -EBUSY;
    else { n->owner = true; kref_get(&n->refs); f->n = n; file->private_data = f; }
    mutex_unlock(&n->lock);
    if (ret) { kfree(f); return ret; }
    return nonseekable_open(inode, file);
}
static int npu_release(struct inode *inode, struct file *file)
{
    struct npu_file *f = file->private_data;
    struct npu_device *n = f->n;
    (void)inode;
    mutex_lock(&n->lock);
    /* VMAs retain the file: ownership persists until all mappings are closed.
     * A crashed accepted job/lease permanently blocks later mutation, until
     * explicit board recovery outside this driver establishes a fresh boot. */
    if (f->task || f->lease) n->orphaned = true;
    n->owner = false;
    mutex_unlock(&n->lock);
    kref_put(&n->refs, npu_free);
    kfree(f);
    return 0;
}
static long npu_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct npu_file *f = file->private_data;
    struct npu_device *n = f->n;
    struct npu_ioc v;
    u32 address, value;
    int ret = 0, k0, k1;
    if (!capable(CAP_SYS_RAWIO)) return -EPERM;
    if (cmd != NPU_IOC_INFO && cmd != NPU_IOC_READ && cmd != NPU_IOC_WRITE &&
        cmd != NPU_IOC_FENCE && cmd != NPU_IOC_KEYS) return -ENOTTY;
    if (copy_from_user(&v, (void __user *)arg, sizeof(v))) return -EFAULT;
    if (v.abi != NPU_RUNTIME_ABI || v.reserved) return -EINVAL;
    mutex_lock(&n->lock);
    if (n->dead) { ret = -ENODEV; goto out; }
    if (cmd == NPU_IOC_INFO) {
        if (v.region >= NPU_REGIONS) { ret = -EINVAL; goto out; }
        v.phys = windows[v.region].phys; v.size = windows[v.region].size;
        v.flags = ddr_region(v.region) ? NPU_MAP_DDR : 0;
        goto out;
    }
    ret = verify_pl(f);
    if (ret) goto out;
    if (cmd == NPU_IOC_READ) {
        if (!allowed_read(v.region, v.offset)) { ret = -EINVAL; goto out; }
        v.value = readl(n->regs[v.region] + v.offset); dma_rmb();
    } else if (cmd == NPU_IOC_KEYS) {
        k0 = gpiod_get_value_cansleep(n->resnet_key);
        k1 = gpiod_get_value_cansleep(n->neu_key);
        if (k0 < 0 || k1 < 0) { ret = k0 < 0 ? k0 : k1; goto out; }
        v.value = (!!k0) | ((!!k1) << 1) | (((~fr(n, 0x344)) & 3) << 2);
    } else if (cmd == NPU_IOC_WRITE) {
        if (!allowed_write(v.region, v.offset, v.value)) { ret = -EINVAL; goto out; }
        ret = guard_write(f, v.region, v.offset, v.value);
        if (ret) goto out;
        if (v.region == NPU_GRAPH && v.offset == 4 && v.value == 1) {
            f->task = true; f->task_id = gr(n, 0x50) + 1;
            f->task_frame = gr(n, 0x28); f->task_generation = gr(n, 0x2c);
        }
        dma_wmb(); writel(v.value, n->regs[v.region] + v.offset);
        readl(n->regs[v.region]);
        if (v.region == NPU_GRAPH && v.offset == 4 && v.value == 4) f->task = false;
        if (v.region == NPU_FRONTEND && v.offset == 8 && fr(n, 0x40)) {
            f->lease = true; f->lease_frame = fr(n, 0x48); f->lease_generation = fr(n, 0x4c);
            address = fr(n, 0x44);
            if (address < 0x12000000 || address > 0x13c00000 ||
                ((address - 0x12000000) & 0x3fffff) || address != fr(n, 0x60) ||
                fr(n, 0x58) != 1280 * 720 * 2) { n->orphaned = true; ret = -EPROTO; }
        }
        if (v.region == NPU_FRONTEND && (v.offset == 0xc || v.offset == 0x120)) {
            value = fr(n, 0x40);
            if (!value) f->lease = false;
            else ret = -EBUSY;
        }
    } else {
        dma_wmb(); dma_rmb(); /* Noncache mappings only; no cached-alias cure. */
    }
out:
    mutex_unlock(&n->lock);
    if (ret) return ret;
    return copy_to_user((void __user *)arg, &v, sizeof(v)) ? -EFAULT : 0;
}
static int npu_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct npu_file *f = file->private_data;
    struct npu_device *n = f->n;
    unsigned long selector = vma->vm_pgoff;
    const struct npu_window *w;
    int ret;
    if (!capable(CAP_SYS_RAWIO)) return -EPERM;
    if (selector >= NPU_REGIONS || !ddr_region(selector)) return -EINVAL;
    w = &windows[selector];
    if (vma->vm_end - vma->vm_start != w->size || !(vma->vm_flags & VM_SHARED) ||
        (vma->vm_flags & VM_EXEC)) return -EINVAL;
    mutex_lock(&n->lock);
    if (n->dead) { ret = -ENODEV; goto out; }
    if (n->orphaned) { ret = -EOWNERDEAD; goto out; }
    ret = verify_pl(f);
    if (ret) goto out;
    /* mmap has no per-load ownership interception. The single trusted daemon
     * must never write leased raw slots or active model/workspace ranges. */
    vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP | VM_DONTCOPY);
    vm_flags_clear(vma, VM_MAYEXEC);
    vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
    vma->vm_pgoff = w->phys >> PAGE_SHIFT;
    ret = remap_pfn_range(vma, vma->vm_start, w->phys >> PAGE_SHIFT, w->size, vma->vm_page_prot);
out:
    mutex_unlock(&n->lock);
    return ret;
}
static const struct file_operations npu_fops = {
    .owner = THIS_MODULE, .open = npu_open, .release = npu_release,
    .unlocked_ioctl = npu_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = compat_ptr_ioctl,
#endif
    .mmap = npu_mmap, .llseek = NULL /* Linux 6.12: absent llseek rejects seeking. */
};
static void disable_clocks(void *data)
{
    struct npu_device *n = data;
    clk_bulk_disable_unprepare(NPU_CLOCK_COUNT, n->clocks);
}
static int npu_probe(struct platform_device *pdev)
{
    struct device_node *region;
    struct reserved_mem *rmem;
    struct npu_device *n;
    struct resource *res;
    unsigned long fclk0_hz, fclk1_hz;
    unsigned int i, mapped = 0;
    int ret;
    region = of_parse_phandle(pdev->dev.of_node, "memory-region", 0);
    if (!region) return -EINVAL;
    rmem = of_reserved_mem_lookup(region);
    if (!rmem || !of_property_read_bool(region, "no-map") ||
        rmem->base != 0x10000000 || rmem->size != 0x10000000) {
        of_node_put(region);
        return dev_err_probe(&pdev->dev, -EINVAL, "require no-map DDR [0x10000000,0x20000000)\n");
    }
    of_node_put(region);
    if (of_property_read_bool(pdev->dev.of_node, "dma-coherent")) return -EINVAL;
    n = kzalloc(sizeof(*n), GFP_KERNEL);
    if (!n) return -ENOMEM;
    mutex_init(&n->lock); kref_init(&n->refs);
    n->clocks = devm_kcalloc(&pdev->dev, NPU_CLOCK_COUNT, sizeof(*n->clocks), GFP_KERNEL);
    if (!n->clocks) { ret = -ENOMEM; goto fail; }
    n->clocks[0].id = "fclk0"; n->clocks[1].id = "fclk1";
    ret = devm_clk_bulk_get(&pdev->dev, NPU_CLOCK_COUNT, n->clocks);
    if (ret) goto fail;
    /* Both current video_system.bd FCLKs are nominally 100 MHz. The Zynq
     * clock provider derives 99,999,999 Hz from the integer 33,333,333 Hz
     * reference and the exported PLL/dividers. Permit only that 1 Hz
     * representation error, never a different operating frequency.
     * The driver holds
     * prepare/enable references so Linux unused-clock cleanup cannot gate PL.
     * Rates are not retuned behind running video/AXI transactions. */
    fclk0_hz = clk_get_rate(n->clocks[0].clk);
    fclk1_hz = clk_get_rate(n->clocks[1].clk);
    if (fclk0_hz < NPU_CLOCK_HZ - NPU_CLOCK_ROUNDING_HZ ||
        fclk0_hz > NPU_CLOCK_HZ + NPU_CLOCK_ROUNDING_HZ ||
        fclk1_hz < NPU_CLOCK_HZ - NPU_CLOCK_ROUNDING_HZ ||
        fclk1_hz > NPU_CLOCK_HZ + NPU_CLOCK_ROUNDING_HZ) {
        ret = dev_err_probe(&pdev->dev, -ERANGE,
                            "require nominal 100 MHz (+/-1 Hz); fclk0=%lu Hz fclk1=%lu Hz\n",
                            fclk0_hz, fclk1_hz);
        goto fail;
    }
    dev_info(&pdev->dev, "FCLK rates: fclk0=%lu Hz fclk1=%lu Hz (nominal 100 MHz)\n",
             fclk0_hz, fclk1_hz);
    ret = clk_bulk_prepare_enable(NPU_CLOCK_COUNT, n->clocks);
    if (ret) goto fail;
    n->resnet_key = devm_gpiod_get(&pdev->dev, "resnet", GPIOD_IN);
    if (IS_ERR(n->resnet_key)) { ret = PTR_ERR(n->resnet_key); goto fail_clock; }
    n->neu_key = devm_gpiod_get(&pdev->dev, "neu", GPIOD_IN);
    if (IS_ERR(n->neu_key)) { ret = PTR_ERR(n->neu_key); goto fail_clock; }
    for (i = 0; i < ARRAY_SIZE(mmio_regions); ++i) {
        unsigned int index = mmio_regions[i];
        res = platform_get_resource(pdev, IORESOURCE_MEM, i);
        if (!res || res->start != windows[index].phys || resource_size(res) != windows[index].size) {
            ret = -EINVAL; goto fail_clock;
        }
        if (!request_mem_region(res->start, resource_size(res), "npu100")) { ret = -EBUSY; goto fail_clock; }
        n->regs[index] = ioremap(res->start, resource_size(res));
        if (!n->regs[index]) { release_mem_region(res->start, resource_size(res)); ret = -ENOMEM; goto fail_clock; }
        ++mapped;
    }
    n->misc.minor = MISC_DYNAMIC_MINOR; n->misc.name = "unified-npu";
    n->misc.fops = &npu_fops; n->misc.parent = &pdev->dev; n->misc.mode = 0600;
    platform_set_drvdata(pdev, n);
    ret = misc_register(&n->misc);
    if (!ret) return 0;
fail_clock:
    for (i = 0; i < mapped; ++i) {
        unsigned int index = mmio_regions[i];
        iounmap(n->regs[index]); release_mem_region(windows[index].phys, windows[index].size);
    }
    disable_clocks(n);
fail:
    kfree(n);
    return ret;
}
static void npu_remove(struct platform_device *pdev)
{
    struct npu_device *n = platform_get_drvdata(pdev);
    unsigned int i;
    misc_deregister(&n->misc);
    mutex_lock(&n->lock);
    n->dead = true;
    for (i = 0; i < ARRAY_SIZE(mmio_regions); ++i) {
        unsigned int index = mmio_regions[i];
        iounmap(n->regs[index]); release_mem_region(windows[index].phys, windows[index].size);
    }
    mutex_unlock(&n->lock);
    disable_clocks(n);
    kref_put(&n->refs, npu_free);
}
static const struct of_device_id npu_match[] = {
    {.compatible = "local,npu100-runtime-v3"}, {}
};
MODULE_DEVICE_TABLE(of, npu_match);
static struct platform_driver npu_driver = {
    .probe = npu_probe, .remove = npu_remove,
    .driver = {.name = "unified-npu", .of_match_table = npu_match, .suppress_bind_attrs = true}
};
module_platform_driver(npu_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("npu100 exclusive ABI8 reserved-DDR interface for Linux 6.12");
