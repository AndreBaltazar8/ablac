/* Spike host: runs a compute SPIR-V with N storage buffers of floats (set 0, bindings 0..), a push-constant block of
   up to 16 bytes, and prints the first values of the last buffer. Usage: host <spv> <entry> <groups> <buffers> <floats-per-buffer> <mode> */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s: %d\n", #x, r_); exit(1); } } while (0)
static uint32_t *readFile(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *size = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *data = malloc(*size); fread(data, 1, *size, f); fclose(f); return data;
}
int main(int argc, char **argv) {
    const char *spv = argv[1], *entry = argv[2]; uint32_t groups = atoi(argv[3]), nbuf = atoi(argv[4]), count = atoi(argv[5]);
    const char *mode = argc > 6 ? argv[6] : "vadd";
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "abla-kernel-spike", 1, 0, 0, VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &app };
    VkInstance instance; CHECK(vkCreateInstance(&ici, 0, &instance));
    uint32_t n = 8; VkPhysicalDevice pds[8]; CHECK(vkEnumeratePhysicalDevices(instance, &n, pds));
    VkPhysicalDevice pd = 0; VkPhysicalDeviceProperties props;
    for (uint32_t i = 0; i < n; i++) { vkGetPhysicalDeviceProperties(pds[i], &props); if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { pd = pds[i]; break; } }
    if (!pd) { pd = pds[0]; vkGetPhysicalDeviceProperties(pd, &props); }
    fprintf(stderr, "device: %s\n", props.deviceName);
    uint32_t qn = 16; VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, qf);
    uint32_t family = 0; for (uint32_t i = 0; i < qn; i++) if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    float prio = 1; VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, family, 1, &prio };
    VkPhysicalDeviceVulkan12Features f12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    f12.shaderInt8 = VK_TRUE; f12.shaderFloat16 = VK_TRUE; f12.storageBuffer8BitAccess = VK_TRUE;
    VkPhysicalDeviceVulkan11Features f11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12 };
    f11.storageBuffer16BitAccess = VK_TRUE;
    VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &f11 };
    VkPhysicalDeviceFeatures2 feats = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f13 };
    feats.features.shaderInt64 = VK_TRUE; feats.features.shaderInt16 = VK_TRUE;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &feats, 0, 1, &qci };
    VkDevice device; CHECK(vkCreateDevice(pd, &dci, 0, &device));
    VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    VkBuffer bufs[8]; VkDeviceMemory mems[8]; void *maps[8]; size_t sizes[8];
    for (uint32_t b = 0; b < nbuf; b++) {
        sizes[b] = (size_t)count * 4;
        if (strcmp(mode, "q4k") == 0 && b == 0) sizes[b] = (size_t)count * 144 / 256 * 4; /* count weights: blocks of 144 bytes per 256 */
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, 0, 0, sizes[b], VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        CHECK(vkCreateBuffer(device, &bci, 0, &bufs[b]));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, bufs[b], &req);
        uint32_t type = 0; for (uint32_t i = 0; i < mp.memoryTypeCount; i++) if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { type = i; break; }
        VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, 0, req.size, type };
        CHECK(vkAllocateMemory(device, &mai, 0, &mems[b])); CHECK(vkBindBufferMemory(device, bufs[b], mems[b], 0));
        CHECK(vkMapMemory(device, mems[b], 0, sizes[b], 0, &maps[b]));
        memset(maps[b], 0, sizes[b]);
    }
    /* inputs: from files in0.bin.. when present, else a[i] = i, b[i] = 2i */
    for (uint32_t b = 0; b + 1 < nbuf; b++) {
        char name[32]; snprintf(name, sizeof name, "in%u.bin", b); FILE *f = fopen(name, "rb");
        if (f) { size_t got = fread(maps[b], 1, sizes[b], f); fclose(f); fprintf(stderr, "%s: %zu bytes\n", name, got); }
        else for (uint32_t i = 0; i < count; i++) ((float *)maps[b])[i] = (float)(i * (b + 1));
    }
    VkDescriptorSetLayoutBinding lb[8];
    for (uint32_t b = 0; b < nbuf; b++) lb[b] = (VkDescriptorSetLayoutBinding){ b, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0 };
    VkDescriptorSetLayoutCreateInfo dlci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, 0, 0, nbuf, lb };
    VkDescriptorSetLayout dsl; CHECK(vkCreateDescriptorSetLayout(device, &dlci, 0, &dsl));
    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
    VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, 0, 0, 1, &dsl, 1, &pcr };
    VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(device, &plci, 0, &layout));
    size_t codeSize; uint32_t *code = readFile(spv, &codeSize);
    VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, 0, 0, codeSize, code };
    VkShaderModule module; CHECK(vkCreateShaderModule(device, &smci, 0, &module));
    VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, 0, 0,
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_COMPUTE_BIT, module, entry }, layout };
    VkPipeline pipeline; CHECK(vkCreateComputePipelines(device, 0, 1, &cpci, 0, &pipeline));
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, nbuf };
    VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, 0, 0, 1, 1, &ps };
    VkDescriptorPool pool; CHECK(vkCreateDescriptorPool(device, &dpci, 0, &pool));
    VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, 0, pool, 1, &dsl };
    VkDescriptorSet set; CHECK(vkAllocateDescriptorSets(device, &dsai, &set));
    VkDescriptorBufferInfo dbi[8]; VkWriteDescriptorSet w[8];
    for (uint32_t b = 0; b < nbuf; b++) { dbi[b] = (VkDescriptorBufferInfo){ bufs[b], 0, VK_WHOLE_SIZE }; w[b] = (VkWriteDescriptorSet){ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, 0, set, b, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0, &dbi[b] }; }
    vkUpdateDescriptorSets(device, nbuf, w, 0, 0);
    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, 0, 0, family };
    VkCommandPool cpool; CHECK(vkCreateCommandPool(device, &cpi, 0, &cpool));
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, 0, cpool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(device, &cbai, &cb));
    VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, 0, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    CHECK(vkBeginCommandBuffer(cb, &cbbi));
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, 0);
    uint32_t push[4] = { count, 0, 0, 0 }; vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, push);
    vkCmdDispatch(cb, groups, 1, 1);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, 0, 0, 0, 0, 1, &cb };
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }; VkFence fence; CHECK(vkCreateFence(device, &fci, 0, &fence));
    CHECK(vkQueueSubmit(queue, 1, &si, fence)); CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 10000000000ull));
    float *out = maps[nbuf - 1];
    FILE *o = fopen("out.bin", "wb"); fwrite(out, 1, sizes[nbuf - 1], o); fclose(o);
    for (uint32_t i = 0; i < 4 && i < count; i++) printf("%g ", out[i]); printf("... %g\n", out[count - 1]);
    return 0;
}
