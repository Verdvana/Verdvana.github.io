---
name: rtl-coding
description: Comprehensive guidelines for writing production-quality RTL code in Verilog and SystemVerilog for hardware design
---

# RTL Coding Guidelines

This skill provides comprehensive guidelines for writing production-quality RTL code in SystemVerilog.

**Purpose**: Comprehensive guidelines for writing SystemVerilog RTL code based on production-quality implementations from high-performance graphics processing unit design.  
**Audience**: Hardware engineers, RTL designers, and AI agents performing RTL design and implementation.  
**Scope**: Applicable to all digital design projects including processors, accelerators, peripherals, and SoC components.

> **Note for AI Agents**: This document provides structured patterns and examples for generating RTL code. Each section includes rationale, implementation patterns, and best practices. Use these patterns as templates, adapting signal names and parameters to match the specific design context.

## When to Use This Skill

Use this skill when you need to:
- Write SystemVerilog RTL code for digital hardware design
- Create module declarations and hierarchies
- Define packages, data types, and structures
- Implement interfaces and port declarations
- Design clock gating and power management
- Write combinational and sequential logic
- Implement FIFOs and memory interfaces
- Create debug and performance monitoring infrastructure
- Follow synthesis and coding best practices

## Table of Contents

1. [Header and Documentation](#1-header-and-documentation)
2. [Module Declaration and Naming](#2-module-declaration-and-naming)
3. [Parameter and Localparam Usage](#3-parameter-and-localparam-usage)
4. [Package and Import Guidelines](#4-package-and-import-guidelines)
5. [Data Types and Structures](#5-data-types-and-structures)
6. [Interface and Port Declarations](#6-interface-and-port-declarations)
7. [Signal Naming Conventions](#7-signal-naming-conventions)
8. [Generate Blocks and Parameterization](#8-generate-blocks-and-parameterization)
9. [Clock and Reset Handling](#9-clock-and-reset-handling)
10. [Combinational and Sequential Logic](#10-combinational-and-sequential-logic)
11. [Debug and Performance Monitoring](#11-debug-and-performance-monitoring)
12. [Comments and Code Documentation](#12-comments-and-code-documentation)
13. [Synthesis and Simulation Directives](#13-synthesis-and-simulation-directives)
14. [FIFO Design and Implementation](#14-fifo-design-and-implementation)
15. [Memory Interface Design](#15-memory-interface-design)
16. [Communication Protocols](#16-communication-protocols)
17. [Synthesis Optimization and Constraints](#17-synthesis-optimization-and-constraints)

---

## 1. Header and Documentation

A comprehensive file header serves multiple critical purposes in professional RTL development. It provides legal protection, version control integration, and essential metadata for project management. The header establishes ownership, tracks changes over time, and helps developers understand the module's purpose and history.

The standardized header format ensures consistency across all project files and integrates seamlessly with version control systems like Perforce or Git. The RCS (Revision Control System) tags are automatically updated by the version control system, providing real-time tracking of file modifications.

### Standard File Header Template
```systemverilog
//------------------------------------------------------------------------------
// COMPANY Proprietary
// Copyright (c) YEAR, COMPANY Incorporated. All rights reserved.
//
// All data and information contained in or disclosed by this document are
// confidential and proprietary information of COMPANY Incorporated, and
// all rights therein are expressly reserved. By accepting this material,
// the recipient agrees that this material and the information contained
// therein are held in confidence and in trust and will not be used,
// copied, reproduced in whole or in part, nor its contents revealed in
// any manner to others without the express written permission of COMPANY
// Incorporated.
//
// This technology was exported from the United States in accordance with
// the Export Administration Regulations. Diversion contrary to U.S. law
// prohibited.
// ------------------------------------------------------------------------------
// RCS File : $Source: /path/to/file $
// Revision : $Revision: x.xx.x.xx $
// Id : $Id: filename.sv,v x.xx.x.xx date time author Exp $
// ------------------------------------------------------------------------------
// Block       : module_name
// Description : Brief description of module functionality
//
//R- Author    : Name (email@domain.com)
//R- Created   : Date
// ------------------------------------------------------------------------------
//R- Revision Log
//R- Who       When     What
//R==============================================================================
//-------------------------------------------------------------------------------
```

### File Naming Convention

Consistent file naming is crucial for large-scale projects where hundreds or thousands of RTL files must be organized and maintained. The naming convention should immediately convey the file's purpose, hierarchical position, and functional area within the design.

The hierarchical naming approach helps developers quickly locate files and understand the design structure. Using lowercase with underscores ensures compatibility across different operating systems and tools, while avoiding potential issues with case-sensitive file systems.

**Naming Rules:**
- Use lowercase with underscores: `gfx_<blk>_cluster_wrap.sv`
- Include block hierarchy: `gfx_<blk>p_prefetch_dbg.sv`
- Suffix with `.sv` for SystemVerilog files
- Include functional indicators: `_core`, `_wrap`, `_ctrl`, `_dbg`

---

## 2. Module Declaration and Naming

Module naming and declaration style form the foundation of readable and maintainable RTL code. A well-structured module declaration immediately communicates the module's purpose, dependencies, and interface to other developers. The naming convention should reflect the design hierarchy and functional relationships between modules.

The systematic approach to module naming enables automated tools to understand design structure and facilitates script-based operations across the design database. Consistent naming also helps with debugging, as signal names in waveforms and synthesis reports directly correspond to the hierarchical structure.

### Module Naming Convention

The hierarchical naming convention serves multiple purposes: it indicates the module's position in the design hierarchy, its functional area, and its specific role within that area. This approach scales effectively from small designs to complex SoCs with thousands of modules.

**Naming Guidelines:**
- Use hierarchical naming: `gfx_<blk>_cluster_wrap`
- Include functional area prefix: `gfx_<blk>p_`, `gfx_<blk>_`
- Use descriptive suffixes: `_wrap`, `_core`, `_ctrl`, `_dbg`
- Maintain consistency across related modules
- Avoid abbreviations that aren't universally understood

### Module Declaration Style

The module declaration format establishes a clear structure that separates concerns: package imports define the type system, parameters configure the module, and ports define the interface. This separation makes the module easier to understand and modify.

Package imports should be placed immediately after the module name to establish the type context before parameters and ports are declared. This ordering ensures that all custom types are available for use in parameter and port declarations.

```systemverilog
module gfx_<blk>_cluster_wrap 
import gfx_common_datatype_pkg::*;
import gfx_<blk>_datatype_pkg::*;
import gfx_usp_datatype_pkg::*;
import gfx_<blk>_internal_pkg::*;
#(
    parameter BLK_CL_ID = 0,
    parameter DV_RAND_DLY = 0
)
(
    // Clock & Reset
    input                                   ares,
    input                                   clk,
    
    // Interface Groups (organized by function)
    gfx_rbbm_cgc_p2s_if.rx                 rbbm_<blk>_cgc,
    gfx_slice_info_if.slice                 slice_id,
    
    // Status outputs
    output logic [NUM_CB_PIPES-1:0]        <blk>_cluster_busy,
    output logic [NUM_CB_PIPES-1:0]        <blk>_cluster_active
);
```

### Key Rules:
- Import packages after module name, before parameters
- Group ports by functionality with comments
- Use consistent indentation (4 spaces)
- Place parameters in separate section with defaults
- Order ports logically: clocks/resets first, status outputs last

---

## 3. Parameter and Localparam Usage

Parameters and localparams are fundamental to creating scalable, configurable RTL designs. They enable design reuse across different configurations and facilitate maintenance by centralizing configuration values. Proper parameter usage distinguishes between externally configurable values (parameters) and internally calculated constants (localparams).

The distinction between parameters and localparams is crucial for design intent and tool optimization. Parameters can be overridden during instantiation, making modules configurable, while localparams are computed internally and cannot be modified externally. This separation ensures design integrity while providing necessary flexibility.

### Parameter Declaration

Parameters should be used sparingly and only for values that genuinely need external configuration. Each parameter should have a clear purpose and sensible default value. Localparams handle all derived calculations and internal constants, keeping the parameter interface clean and focused.

The parameter declaration style should clearly separate external configuration from internal calculations. This organization makes it immediately obvious which values can be modified during instantiation and which are computed internally.

```systemverilog
// Module parameters (configurable from outside)
parameter BLK_CL_ID = 0,
parameter DV_RAND_DLY = 0

// Local parameters (internal calculations)
localparam RBUF_DEPTH = BLK_BUF_DEPTH/2;
localparam CGC_ID_BLK_CLUSTER = get_cgc_id(CGC_P2S_BLK_<BLK>, (BLK_CL_ID + 1));
localparam NUM_BLK_CLUSTER = NUM_BLK_CLUSTERS;
```

### Parameter Naming Rules:

Consistent naming conventions for parameters and localparams improve code readability and reduce errors. The naming should immediately convey the parameter's purpose and data type. Using ALL_CAPS distinguishes parameters from variables and signals.

- Use ALL_CAPS for parameters and localparams
- Use descriptive names: `NUM_BLK_CLUSTERS` not `N_BLK`
- Include width specifications: `ADDR_W`, `DATA_W`
- Use consistent suffixes: `_W` for width, `_DEPTH` for depth
- Avoid abbreviations unless they're industry standard
- Group related parameters with common prefixes

### Localparam Categories:

Organizing localparams into logical categories improves maintainability and helps developers understand the design structure. Each category should group related constants that serve similar purposes within the design.

```systemverilog
// RAM/Memory configuration
localparam BLK_GL_MASTER_RAM_FLOP_SEL = 0;
localparam BLK_IDX_FIFO_MASTER_RAM_FLOP_SEL = 0;
localparam BLK_RBUF_MASTER_RAM_FLOP_SEL = 0;

// Pipeline configuration  
localparam PIPELINE_EN = gfx_common_datatype_pkg::HPGPU_2_5_GHZ_EN;
localparam PIPELINE_MODE__NO_STAGE = 0;
localparam PIPELINE_MODE__STAGE = 1;
localparam PIPELINE_MODE__DCPL = 2;

// Width and depth calculations
localparam FETCH_SRAM_WIDTH = 49;
localparam DEST_SRAM_WIDTH = 12;
localparam IAB_DEPTH = 36;
localparam IAB_ADDR_BIT = $clog2(IAB_DEPTH);

// Performance and timing parameters
localparam MAX_OUTSTANDING_REQUESTS = 16;
localparam TIMEOUT_CYCLES = 1000;
localparam RETRY_LIMIT = 3;
```

---

## 4. Package and Import Guidelines

Package organization is critical for large-scale designs with complex type systems. Packages should be organized hierarchically with clear dependencies and consistent naming. The USP datatype implementation demonstrates sophisticated package organization with conditional compilation and architecture-specific parameters.

### Package Structure and Organization

Packages should be organized by functionality and dependency hierarchy. Common types should be in base packages, while block-specific types should be in dedicated packages. Architecture-specific parameters should be handled through conditional compilation or parameter overrides.

```systemverilog
package gfx_<blk>_datatype_pkg;
    // Include architecture-specific defines
    `include "<blk>_top_defines.vh"
    
    // Import dependencies in order
    import gfx_common_datatype_pkg::*;
    import gfx_hlsq_datatype_pkg::*;
    
    // Architecture-specific parameters with conditional logic
    localparam int NUM_CLUSTER_PER_SP = 2;
    localparam int GFX_<BLK>_VS_IF_QUAD = (GFX_ARCH == 2) ? 1 : ((GFX_ARCH == 4) ? 1 : 2);
    localparam int GFX_<BLK>_FS_IF_QUAD = (GFX_ARCH == 2) ? 2 : ((GFX_ARCH == 4) ? 4 : 8);
    localparam int GFX_<BLK>_WAVE_SIZE = (GFX_ARCH == 2) ? 32 : ((GFX_ARCH == 4) ? 64 : 128);
    
    // Shared constants with descriptive names
    localparam int STCHE_CLI_WIDTH = 6;
    localparam int STCHE_CLI_NULL = 6'd32;
    localparam int STCHE_CLI_OOB = 6'd33;
    localparam int STCHE_CLI_2D = 6'd34;
    
    // Enumeration definitions with comprehensive coverage
    typedef enum logic [5:0] {
        UCOORD        = 0,
        VCOORD        = 1,
        RCOORD        = 2,
        QCOORD        = 3,
        OFFSET_X      = 4,
        OFFSET_Y      = 5,
        OFFSET_Z      = 6,
        MISC          = 7,
        LIGHTZ        = 8,
        LODCLAMP      = 9,
        DUX           = 10,
        DUY           = 11,
        DVX           = 12,
        DVY           = 13,
        DRX           = 14,
        DRY           = 15,
        RAY_BVH_NODE  = 16,
        RAY_ORIGIN_X  = 17,
        RAY_ORIGIN_Y  = 18,
        RAY_ORIGIN_Z  = 19,
        PCMN_A_SCALE  = 20,
        PCMN_F_SCALE  = 21,
        SAD_A_WX_WY   = 22,
        SAD_R_WX_WY   = 23,
        SRC_FBID      = 24,
        FB_DATA       = 25,
        WTEX_U        = 26,
        WTEX_V        = 27,
        WTEX_F        = 28,
        WTEX_B        = 29,
        TENSOR_X      = 30,
        TENSOR_Y      = 31,
        TENSOR_F      = 32,
        TENSOR_B      = 33,
        PACKED_SAMPLE_C0 = 34,
        PACKED_SAMPLE_C1 = 35
    } gfx_<blk>_attr_id_e;
    
    localparam NUM_ATTR = 36; // Document total count for validation
    
    // Complex union structures with opaque overlay
    typedef union packed {
        logic [3:0][31:0]   isamLOD;
        logic [3:0][31:0]   isammSampleID;
        logic [3:0][31:0]   sambLODbias;
        logic [3:0][31:0]   samlLOD;
        logic [3:0][31:0]   convmSampleID;
        logic [3:0][31:0]   getsizeMipLevel;
        logic [3:0][31:0]   getPosSampleID;
        logic [127:0]       opaque;  // Always include opaque for full structure access
    } gfx_<blk>_attr_misc_u;
    
    // Nested structure definitions
    typedef struct packed {
        logic [127:32]    rsvd;
        logic [31:0]      value;
    } gfx_<blk>_attr_derivitive_s;
    
    typedef struct packed {
        gfx_<blk>_attr_derivitive_s  quad;
    } gfx_<blk>_attr_du_dv_dr_s;
    
    // Complex parameterized unions
    typedef union packed {
        gfx_<blk>_attr_coord_s [GFX_<BLK>_NUM_QUAD-1:0]        coord_U;
        gfx_<blk>_attr_coord_s [GFX_<BLK>_NUM_QUAD-1:0]        coord_V;
        gfx_<blk>_attr_coord_s [GFX_<BLK>_NUM_QUAD-1:0]        coord_R;
        gfx_<blk>_attr_coord_s [GFX_<BLK>_NUM_QUAD-1:0]        coord_Q;
        gfx_<blk>_attr_quad_data_u [GFX_<BLK>_NUM_QUAD-1:0]    offset_X;
        gfx_<blk>_attr_quad_data_u [GFX_<BLK>_NUM_QUAD-1:0]    offset_Y;
        gfx_<blk>_attr_quad_data_u [GFX_<BLK>_NUM_QUAD-1:0]    offset_Z;
        gfx_<blk>_attr_misc_u  [GFX_<BLK>_NUM_QUAD-1:0]        misc;
        logic [(GFX_<BLK>_NUM_QUAD*128)-1:0]                   opaque;
    } gfx_<blk>_attr_u;
    
    // Utility functions for type conversion and validation
    function automatic logic is_<blk>_tag;
        input gfx_<blk>_tag_e tag;
        is_<blk>_tag = tag inside { [TAG_SP0:TAG_SP2] };
    endfunction
    
    function automatic gfx_<blk>_tag_e convert_to_<blk>_tag;
        input int index;
        convert_to_<blk>_tag = gfx_<blk>_tag_e'( index + TAG_BASE );
    endfunction
    
endpackage: gfx_<blk>_datatype_pkg
```

### Macro-Based Type Definitions

For complex, repetitive type definitions, use macros to ensure consistency and reduce maintenance overhead. This is particularly useful for interface definitions and parameterized structures.

```systemverilog
// Macro for consistent interface definitions
`define TYPEDEF_ATTR_T \
    typedef union packed { \
        coord_s [NUM_QUAD-1:0]        coord_U; \
        coord_s [NUM_QUAD-1:0]        coord_V; \
        coord_s [NUM_QUAD-1:0]        coord_R; \
        coord_s [NUM_QUAD-1:0]        coord_Q; \
        quad_data_u [NUM_QUAD-1:0]    offset_X; \
        quad_data_u [NUM_QUAD-1:0]    offset_Y; \
        quad_data_u [NUM_QUAD-1:0]    offset_Z; \
        misc_u  [NUM_QUAD-1:0]        misc; \
        logic [(NUM_QUAD*128)-1:0]    opaque; \
    } gfx_<blk>_attr_t;

// Usage in interfaces
`include "example_defns.sv"
interface example_if #(NUM_QUAD=4) (input clk);
    `TYPEDEF_ATTR_T
    
    logic                 srdy;
    logic                 rrdy;
    gfx_<blk>_attr_t     attr_bus;
    
    modport sp (output srdy, attr_bus, input rrdy);
    modport tp (input srdy, attr_bus, output rrdy);
endinterface
```

### Conditional Compilation and Architecture Support

Use conditional compilation to support multiple architectures while maintaining code clarity. Document architecture-specific behavior clearly.

```systemverilog
// Architecture-specific configuration
`ifdef GLYMUR_STAR_HC_MEM
    localparam HC_MEM = 1;
`else
    localparam HC_MEM = 0;
`endif

`ifdef GLYMUR_REG_ARRAY_CGC_DIS
    localparam REG_ARRAY_CGC_EN = 0;
`else
    localparam REG_ARRAY_CGC_EN = 1;
`endif

// Library-specific parameters
`ifdef GFX_<BLK>_LIB_7FF_KONA
    `ifdef RF_MEM_DP
        localparam int <BLK>_GPR_S_ACC_WIDTH = 10;
    `else
        localparam int <BLK>_GPR_S_ACC_WIDTH = 10;
    `endif
`elsif GFX_<BLK>_LIB_14LPE
    localparam int <BLK>_GPR_S_ACC_WIDTH = 8;
`else
    localparam int <BLK>_GPR_S_ACC_WIDTH = 14;
`endif
```

### Import Guidelines and Dependencies

Package imports should follow a strict hierarchy to avoid circular dependencies. Use makefile dependencies to enforce proper compilation order.

**Import Order:**
1. Common datatype packages (gfx_common_datatype_pkg)
2. Shared block packages (gfx_hlsq_datatype_pkg)
3. Block-specific packages (gfx_<blk>_datatype_pkg)
4. Internal packages (gfx_<blk>_internal_pkg)

**Makefile Dependencies:**
```makefile
# makefile.dep - Document package dependencies
gfx_common_datatype
gfx_hlsq_datatype
gfx_tp_ram_pkg
gfx_tp_datatype
```

**Package Import Best Practices:**
- Import packages immediately after module declaration
- Use wildcard imports for commonly used packages
- Group related imports together
- Document any non-obvious dependencies
- Use conditional imports for optional features

---

## 5. Data Types and Structures

Data type definitions are the foundation of SystemVerilog's type system and enable creation of complex, self-documenting designs. Proper type organization improves code readability, reduces errors, and facilitates design reuse. The type system should be hierarchical, with common types in shared packages and specialized types in block-specific packages.

### Structure Definition Guidelines

Structures should be packed for synthesis and clearly document bit allocation. Field ordering should follow a logical pattern, typically with control fields first, followed by data fields, and status fields last. Always include reserved fields for future expansion in critical structures.

```systemverilog
typedef struct packed {
    // Control fields (MSB)
    logic                       valid;
    logic                       last;
    logic [2:0]                 cmd_type;
    logic [1:0]                 priority;
    
    // Address and data fields
    logic [ADDR_WIDTH-1:0]      addr;
    logic [DATA_WIDTH-1:0]      data;
    logic [DATA_WIDTH/8-1:0]    byte_enable;
    
    // Identification fields
    logic [TXN_ID_WIDTH-1:0]    transaction_id;
    logic [SRC_ID_WIDTH-1:0]    source_id;
    
    // Status and control (LSB)
    logic                       error;
    logic                       timeout;
    logic [1:0]                 reserved;  // For future expansion
} memory_request_s;

// Complex nested structure example
typedef struct packed {
    logic [7:0]                 reg_id;
    logic [3:0]                 write_mask;
    logic [VFD_ATTR_DATA_W-1:0] data;
    logic                       shared;
    logic                       attr_valid;
    logic                       last_attr;
    logic                       no_more_iab;
} decoder_packed_attr_s;
```

### Union Usage and Best Practices

Unions provide multiple views of the same data and are essential for protocol conversion and data interpretation. Always include an opaque member for full-width access and debugging. Document the purpose of each union member clearly.

```systemverilog
typedef union packed {
    // Structured access for different instruction types
    struct packed {
        logic [31:24]   opcode;
        logic [23:16]   dest_reg;
        logic [15:8]    src1_reg;
        logic [7:0]     src2_reg;
    } r_type;
    
    struct packed {
        logic [31:24]   opcode;
        logic [23:16]   dest_reg;
        logic [15:8]    src_reg;
        logic [7:0]     immediate;
    } i_type;
    
    struct packed {
        logic [31:24]   opcode;
        logic [23:0]    jump_addr;
    } j_type;
    
    // Raw access for debugging and protocol conversion
    logic [31:0]        raw_instruction;
    logic [3:0][7:0]    byte_array;
    
    // Always include opaque for full structure access
    logic [31:0]        opaque;
} instruction_format_u;

// Complex union with parameterized arrays (from USP analysis)
typedef union packed {
    coordinate_s [NUM_QUAD-1:0]         coord_U;
    coordinate_s [NUM_QUAD-1:0]         coord_V;
    coordinate_s [NUM_QUAD-1:0]         coord_R;
    coordinate_s [NUM_QUAD-1:0]         coord_Q;
    quad_data_u [NUM_QUAD-1:0]          offset_X;
    quad_data_u [NUM_QUAD-1:0]          offset_Y;
    quad_data_u [NUM_QUAD-1:0]          offset_Z;
    misc_data_u [NUM_QUAD-1:0]          misc;
    logic [(NUM_QUAD*128)-1:0]          opaque;  // Full-width access
} graphics_attribute_u;
```

### Enumeration Design Patterns

Enumerations should use explicit values for hardware interfaces and include comprehensive coverage of all valid states. Use appropriate bit widths and consider one-hot encoding for performance-critical state machines.

```systemverilog
// Standard binary encoding for simple state machines
typedef enum logic [2:0] {
    IDLE              = 3'b000,
    FETCH             = 3'b001,
    DECODE            = 3'b010,
    EXECUTE           = 3'b011,
    WRITEBACK         = 3'b100,
    ERROR_RECOVERY    = 3'b101
    // Reserve 3'b110, 3'b111 for future states
} processor_state_e;

// One-hot encoding for performance-critical paths
typedef enum logic [7:0] {
    RESET_STATE       = 8'b00000001,
    INIT_STATE        = 8'b00000010,
    ACTIVE_STATE      = 8'b00000100,
    WAIT_STATE        = 8'b00001000,
    FLUSH_STATE       = 8'b00010000,
    ERROR_STATE       = 8'b00100000,
    RECOVERY_STATE    = 8'b01000000,
    SHUTDOWN_STATE    = 8'b10000000
} cache_controller_state_e;

// Hardware interface enumeration with explicit values
typedef enum logic [5:0] {
    CMD_NOP           = 6'h00,
    CMD_READ          = 6'h01,
    CMD_WRITE         = 6'h02,
    CMD_READ_MODIFY   = 6'h03,
    CMD_FLUSH         = 6'h10,
    CMD_INVALIDATE    = 6'h11,
    CMD_PREFETCH      = 6'h20,
    CMD_BARRIER       = 6'h30,
    CMD_ATOMIC_ADD    = 6'h31,
    CMD_ATOMIC_CAS    = 6'h32,
    CMD_DEBUG_READ    = 6'h3E,
    CMD_DEBUG_WRITE   = 6'h3F
} memory_command_e;

// Document total count for validation and array sizing
localparam NUM_MEMORY_COMMANDS = 12;
```

### Advanced Type Patterns

For complex designs, use advanced SystemVerilog features like parameterized types, type definitions with functions, and hierarchical type organization.

```systemverilog
// Parameterized structure for reusable components
typedef struct packed {
    logic                       valid;
    logic                       ready;
    logic [ADDR_W-1:0]          address;
    logic [DATA_W-1:0]          data;
    logic [DATA_W/8-1:0]        strobe;
    logic [ID_W-1:0]            id;
} generic_bus_transaction_s #(
    parameter ADDR_W = 32,
    parameter DATA_W = 64,
    parameter ID_W = 8
);

// Type definitions with utility functions
typedef logic [COORD_WIDTH-1:0] coordinate_t;

function automatic coordinate_t add_coordinates(
    input coordinate_t a,
    input coordinate_t b
);
    add_coordinates = a + b;
endfunction

function automatic logic coordinates_equal(
    input coordinate_t a,
    input coordinate_t b
);
    coordinates_equal = (a == b);
endfunction

// Hierarchical type organization
typedef struct packed {
    logic [15:0]    x;
    logic [15:0]    y;
    logic [15:0]    z;
    logic           valid;
} vertex_3d_s;

typedef struct packed {
    vertex_3d_s [2:0]   vertices;  // Triangle vertices
    logic [7:0]         material_id;
    logic [3:0]         flags;
    logic               visible;
} triangle_s;

typedef struct packed {
    triangle_s [MAX_TRIANGLES-1:0]  triangles;
    logic [15:0]                    triangle_count;
    logic [31:0]                    mesh_id;
} mesh_s;
```

### Type Naming Conventions and Organization

Consistent naming conventions are essential for maintainable code. Follow these rules strictly across all type definitions:

**Naming Rules:**
- **Structures**: `_s` suffix (e.g., `memory_request_s`)
- **Unions**: `_u` suffix (e.g., `instruction_format_u`)
- **Enumerations**: `_e` suffix (e.g., `processor_state_e`)
- **Type aliases**: `_t` suffix (e.g., `coordinate_t`)
- **Interfaces**: `_if` suffix (e.g., `memory_bus_if`)

**Organization Guidelines:**
- Group related types in the same package
- Use consistent field ordering within structures
- Document bit allocation and field purposes
- Include version information for evolving types
- Provide utility functions for complex types

### Type Safety and Validation

Include compile-time and runtime validation for critical types to catch errors early and ensure design integrity.

```systemverilog
// Compile-time validation using static assertions
typedef struct packed {
    logic [ADDR_WIDTH-1:0]  addr;
    logic [DATA_WIDTH-1:0]  data;
    logic [ID_WIDTH-1:0]    id;
} validated_transaction_s;

// Static assertions for type validation
initial begin
    assert (ADDR_WIDTH >= 16) else $fatal("Address width too small");
    assert (DATA_WIDTH % 8 == 0) else $fatal("Data width must be byte-aligned");
    assert ($bits(validated_transaction_s) <= MAX_TRANSACTION_BITS) 
        else $fatal("Transaction structure too large");
end

// Runtime validation functions
function automatic logic is_valid_command(memory_command_e cmd);
    case (cmd)
        CMD_NOP, CMD_READ, CMD_WRITE, CMD_READ_MODIFY,
        CMD_FLUSH, CMD_INVALIDATE, CMD_PREFETCH, CMD_BARRIER,
        CMD_ATOMIC_ADD, CMD_ATOMIC_CAS, CMD_DEBUG_READ, CMD_DEBUG_WRITE:
            is_valid_command = 1'b1;
        default:
            is_valid_command = 1'b0;
    endcase
endfunction
```

---

## 6. Interface and Port Declarations

### Interface Usage
```systemverilog
// Use SystemVerilog interfaces for complex protocols
gfx_rl_if.target                    cp_vfdp_rl[NUM_CB_PIPES],
gfx_rbbm_cgc_p2s_if.rx             rbbm_cgc_p2s_slice,
gfx_pc_s_vfd_fiber_if.vfd          pc_vfdp_fiber[NUM_GPC_SLICE_INTF],

// Use modports to specify direction
gfx_vfd_cche_req_if.vfd            vfd_cche_req[NUM_VFD],
gfx_cche_vfd_rdata_if.vfd          cche_vfd_rdata[NUM_VFD],
```

### Port Organization:
1. Clock and Reset (always first)
2. Configuration interfaces
3. Data interfaces (grouped by function)
4. Control interfaces
5. Debug interfaces
6. Status outputs (always last)

### Array Port Declaration:
```systemverilog
// Use consistent array notation
input  logic [NUM_CB_PIPES-1:0]     vfd_busy,
output logic [NUM_SP_PER_SLICE-1:0] vfd_hlsq_br_workload_busy,

// For interface arrays, specify range clearly
gfx_vfd_hlsq_info_if.vfd           vfd_hlsq_info[NUM_VFD_CLUSTERS * NUM_CB_PIPES],
```

---

## 7. Signal Naming Conventions

### Naming Rules:
- Use lowercase with underscores: `vfd_cluster_busy`
- Include hierarchy in name: `vfd_cluster_cgw_wake_up`
- Use consistent suffixes:
  - `_srdy`, `_rrdy` for ready signals
  - `_valid` for valid signals
  - `_en` for enable signals
  - `_sel` for select signals
  - `_cnt` for counters
  - `_ptr` for pointers
  - `_busy`, `_active` for status
  - `_rt` for retimed signals

### Signal Grouping:
```systemverilog
// Group related signals with consistent naming
logic [NUM_CB_PIPES-1:0]                vfd_busy;
logic [NUM_CB_PIPES-1:0]                vfd_active;
logic [NUM_CB_PIPES-1:0]                vfd_error;

// Use arrays for multi-dimensional signals
logic [NUM_CB_PIPES-1:0][NUM_VFD_CLUSTERS-1:0] vfd_cluster_cb_busy;
logic [NUM_VFD_CLUSTERS-1:0][NUM_CB_PIPES-1:0] vfd_cluster_busy;
```

### Temporary/Internal Signals:
```systemverilog
// Use descriptive suffixes for internal signals
logic [NUM_CB_PIPES-1:0]    pc_vfd_pass1_wave_done_rt;      // retimed
logic [NUM_CB_PIPES-1:0]    vfd_ctxt_done_decr_t;           // temporary
logic [NUM_CB_PIPES-1:0]    vfd_ctxt_done_decr_o;           // output
logic [NUM_CB_PIPES-1:0]    vfd_cluster_ctxt_done_int;      // internal
```

---

## 8. Generate Blocks and Parameterization

### Generate Block Style:
```systemverilog
generate
for (genvar g0=0; g0<NUM_VFD_CLUSTERS; g0++) begin: VFD_CLUSTERS
    gfx_vfd_cluster_wrap #(
        .VFD_CL_ID         ( g0 ),
        .DV_RAND_DLY       ( DV_RAND_DLY )
    ) u_vfd_cluster (
        .clk               ( clk ),
        .ares              ( vfd_ares[g0] ),
        .vfd_cluster_busy  ( vfd_cluster_busy[g0] ),
        .vfd_cluster_active( vfd_cluster_active[g0] )
    );
end
endgenerate
```

### Generate Rules:
- Use descriptive genvar names: `g0`, `h0`, `i0` (not `i`, `j`, `k`)
- Use meaningful block names: `VFD_CLUSTERS`, `PER_CB`, `PER_CORE`
- Indent generate contents consistently
- Use generate for all parameterized instantiations

### Conditional Generate:
```systemverilog
generate
if (NUM_CB_PIPES == 2) begin: CB_BUSY
    assign vfd_hlsq_bv_workload_busy[h0] = vfd_hlsq_workload_busy[1][h0];
end
else begin: BV_TIE
    assign vfd_hlsq_bv_workload_busy[h0] = 1'b0;
end
endgenerate
```

---

## 9. Clock and Reset Handling

Clock and reset design is fundamental to reliable digital systems. Proper clock distribution, reset synchronization, and power management directly impact system performance, power consumption, and reliability. Clock gating is essential for power optimization in modern designs, while reset strategies ensure predictable system initialization and recovery.

### Clock and Reset Declaration

Clock and reset signals should follow consistent naming conventions and be properly documented. Multiple clock domains require careful consideration of clock domain crossing (CDC) issues. Reset hierarchy should match the design hierarchy to enable selective reset of subsystems.

```systemverilog
// Standard clock and reset naming
input                           clk,                     // Primary system clock
input                           ares,                    // Asynchronous reset (active high)
input                           <blk>p_ares,            // Module-specific async reset
input                           <blk>_ares[NUM_CLUSTERS], // Per-cluster reset array

// Clock domain specific signals
input                           clk_core,                // Core logic clock (gated)
input                           clk_mem,                 // Memory interface clock
input                           clk_debug,               // Debug interface clock (always-on)

// Reset synchronizers for different domains
logic                           core_reset_sync;
logic                           mem_reset_sync;
```

### Clock Gating Implementation

Clock gating is critical for power reduction in high-performance designs. The clock gating controller should provide configurable wake-up conditions, hysteresis to prevent excessive gating/ungating, and debug visibility. Proper clock gating can reduce dynamic power by 20-50% in typical designs.

```systemverilog
// Clock gating controller with comprehensive configuration
gfx_cgctrl_leaf #(
    .NUM_WAKE_UP        ( CGC_SIG_NUM_<BLK> ),           // Number of wake-up signals
    .CLK_ALIVE_BIT      ( NUM_CLK_ALIVE_<BLK> ),         // Always-on clock bits
    .CGC_ID             ( CGC_ID_<BLK> ),                // Unique CGC identifier
    .CGC_MODE           ( CGC_MODE_<BLK> ),              // Gating mode (aggressive/conservative)
    .CGC_DELAY          ( CGC_DELAY_<BLK> ),             // Gating delay cycles
    .CGC_HYST           ( CGC_HYST_<BLK> ),              // Hysteresis cycles
    .CGC_FORCE_ON       ( CGC_FORCE_ON_<BLK> )           // Force-on for debug
) u_cgctrl (
    .ares                      ( ares ),
    .clk                       ( clk ),
    .clk_core                  ( clk_core ),             // Gated output clock
    .clk_alive                 ( clk_alive ),            // Always-on clock
    .cgw_cgctrl_wake_up        ( cgw_cgctrl_wake_up ),   // Wake-up condition signals
    .cgw_cgctrl_keep_on        ( cgw_cgctrl_keep_on ),   // Keep-on condition signals
    .cgc_status                ( cgc_status ),           // Gating status for debug
    .cgc_override              ( cgc_debug_override )    // Debug override control
);

// Wake-up signal generation
assign cgw_cgctrl_wake_up = {
    fifo_not_empty,           // Data available for processing
    interface_request_pending, // External request pending
    state_machine_active,     // State machine not idle
    error_condition,          // Error requires attention
    debug_access_active       // Debug access in progress
};

// Keep-on signal generation  
assign cgw_cgctrl_keep_on = {
    critical_operation_active, // Critical operation in progress
    memory_transaction_pending,// Memory access pending
    reset_sequence_active,    // Reset/initialization sequence
    performance_monitor_active // Performance monitoring enabled
};
```

### Reset Synchronization and Distribution

Reset synchronization prevents metastability issues while ensuring proper reset release timing. Reset distribution should be hierarchical and match the clock distribution to minimize skew and ensure reliable operation.

```systemverilog
// Reset synchronizer for core domain
always_ff @(posedge clk_core or posedge ares) begin
    if (ares) begin
        core_reset_sync_ff1 <= 1'b1;
        core_reset_sync_ff2 <= 1'b1;
        core_reset_sync     <= 1'b1;
    end else begin
        core_reset_sync_ff1 <= 1'b0;
        core_reset_sync_ff2 <= core_reset_sync_ff1;
        core_reset_sync     <= core_reset_sync_ff2;
    end
end

// Reset distribution tree with proper buffering
generate
for (genvar i = 0; i < NUM_CLUSTERS; i++) begin: RESET_DISTRIBUTION
    // Local reset buffer for each cluster
    logic cluster_reset_local;
    
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            cluster_reset_local <= 1'b1;
        end else begin
            cluster_reset_local <= core_reset_sync | cluster_specific_reset[i];
        end
    end
    
    assign <blk>_ares[i] = cluster_reset_local;
end
endgenerate
```

### Power Management Integration

Power management should be integrated with clock gating to provide comprehensive power optimization. This includes voltage scaling coordination, retention register control, and power domain isolation.

```systemverilog
// Power management controller interface
typedef struct packed {
    logic       power_down_req;      // Power down request
    logic       retention_enable;    // Enable retention registers
    logic       isolation_enable;    // Enable power domain isolation
    logic [3:0] voltage_level;       // Target voltage level
    logic       dvfs_transition;     // Dynamic voltage/frequency scaling
} power_mgmt_ctrl_s;

// Power state machine
typedef enum logic [2:0] {
    PWR_ACTIVE    = 3'b000,
    PWR_IDLE      = 3'b001,
    PWR_DROWSY    = 3'b010,
    PWR_RETENTION = 3'b011,
    PWR_OFF       = 3'b100
} power_state_e;

power_state_e current_power_state, next_power_state;

// Power state transitions with proper sequencing
always_ff @(posedge clk or posedge ares) begin
    if (ares) begin
        current_power_state <= PWR_ACTIVE;
        power_transition_counter <= '0;
    end else begin
        current_power_state <= next_power_state;
        if (current_power_state != next_power_state) begin
            power_transition_counter <= power_transition_counter + 1;
        end
    end
end
```

### Sequential Logic Template with Advanced Features

```systemverilog
// Comprehensive sequential logic template with error handling
always_ff @ (posedge clk or posedge ares) begin
    if (ares) begin
        // Reset all registers to known states
        signal <= '0;
        counter <= '0;
        state_machine <= IDLE;
        error_flags <= '0;
        transaction_id <= '0;
    end else begin
        // Default assignments to prevent latches
        error_flags.timeout <= 1'b0;
        error_flags.overflow <= 1'b0;
        
        if (enable) begin
            signal <= next_signal;
            counter <= counter + 1;
            
            // Timeout detection
            if (counter > TIMEOUT_THRESHOLD) begin
                error_flags.timeout <= 1'b1;
                counter <= '0;
            end
            
            // Overflow protection
            if (counter == MAX_COUNT) begin
                error_flags.overflow <= 1'b1;
                counter <= '0;
            end
        end
        
        // State machine with error handling
        case (state_machine)
            IDLE: begin
                if (start_request) begin
                    state_machine <= ACTIVE;
                    transaction_id <= transaction_id + 1;
                end
            end
            
            ACTIVE: begin
                if (completion_detected) begin
                    state_machine <= IDLE;
                end else if (error_detected) begin
                    state_machine <= ERROR_RECOVERY;
                end
            end
            
            ERROR_RECOVERY: begin
                if (recovery_complete) begin
                    state_machine <= IDLE;
                    error_flags <= '0;
                end
            end
            
            default: begin
                state_machine <= IDLE;  // Safe fallback
                error_flags.invalid_state <= 1'b1;
            end
        endcase
    end
end
```

---

## 10. Combinational and Sequential Logic

### Combinational Logic:
```systemverilog
// Use always_comb for combinational logic
always_comb begin
    pc_vfdp_fiber_srdy[g0] = pc_vfdp_fiber[g0].srdy;
    pc_vfd_pass1_wave_done_srdy[g0] = pc_vfd_pass1_wave_done[g0].srdy;
    vfd_pc_us_dealloc_srdy[g0] = (g0==0) ? '0 : vfd_pc_us_dealloc.srdy;
end

// Use assign for simple assignments
assign vfd_error[g0] = '0;
assign vfd_cluster_error = '0;
```

### Complex Combinational Logic:
```systemverilog
always_comb begin
    vfd_attr_miss_count = '0;
    for(int i=0; i<NUM_VFD_CLUSTERS; i++) 
        vfd_attr_miss_count = (vfd_attr_miss_count + ({'0, vfd_attr_dealloc_count[i]}));
end
```

### Sequential Logic Best Practices:
- Always use non-blocking assignments (`<=`) in clocked blocks
- Use blocking assignments (`=`) in combinational blocks
- Initialize all registers in reset condition
- Use `'0` for zero initialization of any width

---

## 11. Debug and Performance Monitoring

Debug infrastructure and performance monitoring are critical for silicon bring-up, performance optimization, and field debugging. A well-designed debug system provides visibility into internal operations without significantly impacting area, power, or timing. The debug infrastructure should be planned early in the design phase and integrated systematically throughout the design hierarchy.

Performance counters enable quantitative analysis of design behavior, bottleneck identification, and performance optimization. They should capture key metrics that directly relate to system performance and provide actionable insights for both hardware and software teams.

### Debug Bus Implementation

The debug bus provides real-time visibility into internal signals and state machines. Signal selection should focus on critical control paths, state transitions, and interface handshakes. The debug bus width is typically constrained, so signal prioritization is essential.

**Debug Signal Selection Criteria:**
- State machine states and transition triggers
- Interface handshake signals (srdy/rrdy pairs)
- FIFO full/empty status and occupancy
- Error conditions and exception states
- Performance-critical control signals
- Clock gating and power management states

```systemverilog
// Debug bus signal naming convention
logic [63:0]    GFX_DBGBUS_misr_data_<blk>_fetch;
logic [63:0]    GFX_DBGBUS_misr_data_<blk>_decode;
logic [3:0]     GFX_DBGBUS_misr_side_<blk>_fetch;
logic [3:0]     GFX_DBGBUS_misr_side_<blk>_decode;

// Debug bus assignments with detailed bit allocation
// DEBBUS_DEFINE_BEGIN_BV    top_block=<blk>; my_block=fetch_dbg; radix=10;
assign GFX_DBGBUS_misr_data_<blk>_fetch[0]     = fetch_state_machine.current_state[0];
assign GFX_DBGBUS_misr_data_<blk>_fetch[3:1]   = fetch_state_machine.current_state[3:1];
assign GFX_DBGBUS_misr_data_<blk>_fetch[4]     = fetch_fifo_full;
assign GFX_DBGBUS_misr_data_<blk>_fetch[5]     = fetch_fifo_empty;
assign GFX_DBGBUS_misr_data_<blk>_fetch[13:6]  = fetch_fifo_occupancy[7:0];
assign GFX_DBGBUS_misr_data_<blk>_fetch[14]    = interface_srdy;
assign GFX_DBGBUS_misr_data_<blk>_fetch[15]    = interface_rrdy;
assign GFX_DBGBUS_misr_data_<blk>_fetch[16]    = error_detected;
assign GFX_DBGBUS_misr_data_<blk>_fetch[17]    = timeout_occurred;
assign GFX_DBGBUS_misr_data_<blk>_fetch[25:18] = transaction_id[7:0];
assign GFX_DBGBUS_misr_data_<blk>_fetch[26]    = clock_gated;
assign GFX_DBGBUS_misr_data_<blk>_fetch[27]    = power_down_req;
assign GFX_DBGBUS_misr_data_<blk>_fetch[63:28] = debug_timestamp[35:0];

// Side channel for transaction tracking
assign GFX_DBGBUS_misr_side_<blk>_fetch[0]     = interface_srdy & interface_rrdy;  // Valid transaction
assign GFX_DBGBUS_misr_side_<blk>_fetch[1]     = interface_srdy;                   // Request pending
assign GFX_DBGBUS_misr_side_<blk>_fetch[2]     = error_detected;                   // Error condition
assign GFX_DBGBUS_misr_side_<blk>_fetch[3]     = state_transition;                 // State change
// DEBBUS_DEFINE_END_BV
```

### Performance Counter Structure

Performance counters should be organized hierarchically to provide both high-level system metrics and detailed subsystem analysis. Counter width should be sufficient to avoid overflow during typical measurement periods, typically 32 or 64 bits.

**Performance Counter Categories:**
- **Utilization Counters**: Measure resource usage (busy cycles, active cycles)
- **Stall Counters**: Track pipeline stalls and bottlenecks
- **Throughput Counters**: Count transactions, operations, or data transfers
- **Latency Counters**: Measure response times and processing delays
- **Error Counters**: Track error conditions and recovery events
- **Power Counters**: Monitor clock gating effectiveness and power states

```systemverilog
typedef struct packed {
    // Utilization metrics
    logic [31:0]        pfc_busy_cycles;
    logic [31:0]        pfc_active_cycles;
    logic [31:0]        pfc_idle_cycles;
    
    // Stall analysis
    logic [31:0]        pfc_stall_cycles_input_fifo_full;
    logic [31:0]        pfc_stall_cycles_output_fifo_full;
    logic [31:0]        pfc_stall_cycles_memory_conflict;
    logic [31:0]        pfc_stall_cycles_resource_unavail;
    
    // Throughput measurements
    logic [31:0]        pfc_transactions_completed;
    logic [31:0]        pfc_bytes_processed;
    logic [31:0]        pfc_operations_per_cycle;
    
    // Latency tracking
    logic [31:0]        pfc_avg_latency_cycles;
    logic [31:0]        pfc_max_latency_cycles;
    logic [31:0]        pfc_min_latency_cycles;
    
    // Error monitoring
    logic [15:0]        pfc_error_count;
    logic [15:0]        pfc_timeout_count;
    logic [15:0]        pfc_retry_count;
    
    // Power and clock gating
    logic [31:0]        pfc_clock_gated_cycles;
    logic [31:0]        pfc_power_down_cycles;
    logic [7:0]         pfc_cgc_efficiency_percent;
} block_performance_counters_s;

// Performance counter implementation with enable control
always_ff @(posedge clk or posedge ares) begin
    if (ares) begin
        perf_counters <= '0;
    end else if (perf_counter_enable) begin
        // Increment counters based on conditions
        if (block_busy) 
            perf_counters.pfc_busy_cycles <= perf_counters.pfc_busy_cycles + 1;
        if (input_stall)
            perf_counters.pfc_stall_cycles_input_fifo_full <= perf_counters.pfc_stall_cycles_input_fifo_full + 1;
        if (transaction_complete)
            perf_counters.pfc_transactions_completed <= perf_counters.pfc_transactions_completed + 1;
        if (error_detected)
            perf_counters.pfc_error_count <= perf_counters.pfc_error_count + 1;
    end
end
```

### Advanced Debug Features

**Trigger and Capture Logic:**
```systemverilog
// Debug trigger conditions
logic debug_trigger_condition;
logic [7:0] debug_trigger_count;

always_comb begin
    debug_trigger_condition = (state_machine == ERROR_STATE) |
                             (fifo_overflow_detected) |
                             (timeout_counter > TIMEOUT_THRESHOLD) |
                             (performance_degradation_detected);
end

// Circular buffer for debug data capture
logic [DEBUG_BUFFER_DEPTH-1:0][DEBUG_DATA_WIDTH-1:0] debug_capture_buffer;
logic [DEBUG_ADDR_WIDTH-1:0] debug_write_ptr;

always_ff @(posedge clk or posedge ares) begin
    if (ares) begin
        debug_write_ptr <= '0;
        debug_capture_buffer <= '0;
    end else if (debug_capture_enable) begin
        debug_capture_buffer[debug_write_ptr] <= {
            current_timestamp,
            state_machine_state,
            interface_status,
            error_flags,
            performance_indicators
        };
        debug_write_ptr <= debug_write_ptr + 1;
    end
end
```

---

## 12. Comments and Code Documentation

### Section Headers:
```systemverilog
//==============================================================================
// Clock Gating Controller
//==============================================================================

//============================================================================
// VFD CLUSTERS 
//============================================================================

//==============================================================================
// Import Packages
//==============================================================================
```

### Inline Comments:
```systemverilog
// TODO: Use NUM_MICRO_SP_PER_SP ??
if (NUM_SPTP_PER_SP == 2) begin : PC_PASS1_WAVE_DONE
    // Handle dual SPTP case
    assign pc_vfd_pass1_wave_done_rt[g0].rrdy = pc_vfd_pass1_wave_done_rt[g0].payload.sptp_id[1] ? 
                                                pc_dqsync_pass1_done[g0+NUM_CB_PIPES].rrdy :
                                                pc_dqsync_pass1_done[g0].rrdy;
end

// Retiming buffer for performance
gfx_retiming_fifo #(
    .DSIZE    ( $bits(pc_vfd_pass1_wave_done_s) ),
    .NUM_INST ( GFX_GPC_VFD_PC_PASS1_BUF_NUM[g0] )
) u_pc_vfd_pass_1_done_retiming_buf (
    // connections...
);
```

### Function Documentation:
```systemverilog
// Function: get_cgc_id
// Purpose: Calculate clock gating controller ID based on block and instance
// Parameters: 
//   - blk_id: Block identifier
//   - inst_id: Instance identifier within block
// Returns: Calculated CGC ID
```

---

## 13. Synthesis and Simulation Directives

### Synthesis Directives:
```systemverilog
//synopsys translate_off
// Simulation-only code
logic [NUM_VFD_PER_SP*NUM_VFD_CLUSTERS -1 :0]                   vfd_uche_req_state_id_lsb;
logic [NUM_VFD_PER_SP*NUM_VFD_CLUSTERS -1 :0][VFD_CTXTID_W-1:0] vfd_uche_req_ctxt_id;
//synopsys translate_on
```

### Conditional Compilation:
```systemverilog
`ifdef VFD_DV_RAND_DLY_FIFO
    localparam DV_RAND_DLY = 1;
`else
    localparam DV_RAND_DLY = 0;
`endif

`ifdef GFX_VFD_WBOX_COV
    `include "gfx_vfd_top_wb.sv"
`endif
```

### Coverage Exclusions:
```systemverilog
//synopsys translate_off
`ifdef WBOX_COV_EN
    `include "gfx_vfd_cluster_wb.sv"
`endif
//synopsys translate_on
```

---

## 14. FIFO Design and Implementation

FIFOs are fundamental building blocks in digital systems, providing data buffering, clock domain crossing, and flow control. Proper FIFO design ensures data integrity, optimal performance, and reliable operation across varying conditions.

### FIFO Architecture and Sizing

FIFO depth should be determined based on system requirements, including burst sizes, latency tolerance, and throughput requirements. Shallow FIFOs (2-8 entries) are suitable for simple buffering, while deep FIFOs (64+ entries) handle large bursts and provide substantial buffering.

```systemverilog
// Parameterized FIFO with comprehensive features
module gfx_<blk>_fifo #(
    parameter DEPTH = 16,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = $clog2(DEPTH),
    parameter ALMOST_FULL_THRESH = DEPTH - 4,
    parameter ALMOST_EMPTY_THRESH = 4,
    parameter SYNC_STAGES = 2,
    parameter RAM_STYLE = "auto"  // "auto", "distributed", "block"
)(
    // Write interface
    input                           wr_clk,
    input                           wr_ares,
    input                           wr_en,
    input  [DATA_WIDTH-1:0]         wr_data,
    output                          wr_full,
    output                          wr_almost_full,
    output [ADDR_WIDTH:0]           wr_count,
    
    // Read interface  
    input                           rd_clk,
    input                           rd_ares,
    input                           rd_en,
    output [DATA_WIDTH-1:0]         rd_data,
    output                          rd_empty,
    output                          rd_almost_empty,
    output [ADDR_WIDTH:0]           rd_count,
    
    // Status and debug
    output                          fifo_error,
    output [ADDR_WIDTH:0]           max_occupancy
);
```

### Retiming FIFOs for Performance

Retiming FIFOs break critical timing paths while maintaining throughput. They should be strategically placed at pipeline boundaries and interface crossings to optimize timing closure.

```systemverilog
// Retiming FIFO for timing optimization
module gfx_retiming_fifo #(
    parameter DSIZE = 64,
    parameter NUM_INST = 2,  // Number of pipeline stages
    parameter BYPASS_EN = 0  // Enable bypass for zero latency
)(
    input                       clk,
    input                       ares,
    
    // Input interface
    input                       data_in_srdy,
    output                      data_in_rrdy,
    input  [DSIZE-1:0]          data_in,
    
    // Output interface
    output                      data_out_srdy,
    input                       data_out_rrdy,
    output [DSIZE-1:0]          data_out,
    
    // Status
    output                      busy
);

// Implementation with configurable stages
generate
if (NUM_INST == 0 || BYPASS_EN) begin: BYPASS_PATH
    assign data_out_srdy = data_in_srdy;
    assign data_in_rrdy = data_out_rrdy;
    assign data_out = data_in;
    assign busy = 1'b0;
end else begin: PIPELINE_STAGES
    logic [NUM_INST:0]          stage_srdy;
    logic [NUM_INST:0]          stage_rrdy;
    logic [NUM_INST-1:0][DSIZE-1:0] stage_data;
    
    assign stage_srdy[0] = data_in_srdy;
    assign data_in_rrdy = stage_rrdy[0];
    assign data_out_srdy = stage_srdy[NUM_INST];
    assign stage_rrdy[NUM_INST] = data_out_rrdy;
    assign data_out = stage_data[NUM_INST-1];
    
    // Pipeline stage implementation
    for (genvar i = 0; i < NUM_INST; i++) begin: STAGE
        always_ff @(posedge clk or posedge ares) begin
            if (ares) begin
                stage_srdy[i+1] <= 1'b0;
                stage_data[i] <= '0;
            end else begin
                if (stage_rrdy[i] || ~stage_srdy[i+1]) begin
                    stage_srdy[i+1] <= stage_srdy[i];
                    if (stage_srdy[i] && stage_rrdy[i]) begin
                        stage_data[i] <= (i == 0) ? data_in : stage_data[i-1];
                    end
                end
            end
        end
        
        // Ready propagation with lookahead
        assign stage_rrdy[i] = ~stage_srdy[i+1] || stage_rrdy[i+1];
    end
    
    // Busy when any stage contains valid data
    assign busy = |stage_srdy[NUM_INST:1];
end
endgenerate
endmodule

### Asynchronous FIFO Implementation

Asynchronous FIFOs enable reliable data transfer between different clock domains. The key challenges include metastability prevention, proper gray code pointer synchronization, and accurate full/empty detection.

```systemverilog
// Asynchronous FIFO with gray code pointers
module gfx_async_fifo #(
    parameter DEPTH = 16,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = $clog2(DEPTH),
    parameter SYNC_STAGES = 2
)(
    // Write domain
    input                       wr_clk,
    input                       wr_ares,
    input                       wr_en,
    input  [DATA_WIDTH-1:0]     wr_data,
    output                      wr_full,
    
    // Read domain
    input                       rd_clk,
    input                       rd_ares,
    input                       rd_en,
    output [DATA_WIDTH-1:0]     rd_data,
    output                      rd_empty,
    
    // Status
    output                      overflow_error,
    output                      underflow_error
);

    // Internal registers
    logic [ADDR_WIDTH:0]        wr_ptr_bin;
    logic [ADDR_WIDTH:0]        rd_ptr_bin;
    logic [ADDR_WIDTH:0]        wr_ptr_gray;
    logic [ADDR_WIDTH:0]        rd_ptr_gray;
    logic [ADDR_WIDTH:0]        wr_ptr_gray_sync;
    logic [ADDR_WIDTH:0]        rd_ptr_gray_sync;
    
    // Memory array
    logic [DATA_WIDTH-1:0]      fifo_mem [0:DEPTH-1];
    
    // Binary to Gray code conversion
    function automatic [ADDR_WIDTH:0] bin_to_gray(input [ADDR_WIDTH:0] bin);
        bin_to_gray = bin ^ (bin >> 1);
    endfunction
    
    // Gray to Binary conversion
    function automatic [ADDR_WIDTH:0] gray_to_bin(input [ADDR_WIDTH:0] gray);
        logic [ADDR_WIDTH:0] bin;
        bin = gray;
        for (int i = 1; i <= ADDR_WIDTH; i = i << 1)
            bin = bin ^ (bin >> i);
        return bin;
    endfunction
    
    // Write pointer logic
    always_ff @(posedge wr_clk or posedge wr_ares) begin
        if (wr_ares) begin
            wr_ptr_bin <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_en && !wr_full) begin
            wr_ptr_bin <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= bin_to_gray(wr_ptr_bin + 1'b1);
        end
    end
    
    // Read pointer logic
    always_ff @(posedge rd_clk or posedge rd_ares) begin
        if (rd_ares) begin
            rd_ptr_bin <= '0;
            rd_ptr_gray <= '0;
        end else if (rd_en && !rd_empty) begin
            rd_ptr_bin <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= bin_to_gray(rd_ptr_bin + 1'b1);
        end
    end
    
    // Synchronize read pointer to write clock domain
    gfx_synchronizer #(
        .WIDTH(ADDR_WIDTH+1),
        .STAGES(SYNC_STAGES)
    ) rd_ptr_synchronizer (
        .clk(wr_clk),
        .ares(wr_ares),
        .data_in(rd_ptr_gray),
        .data_out(rd_ptr_gray_sync)
    );
    
    // Synchronize write pointer to read clock domain
    gfx_synchronizer #(
        .WIDTH(ADDR_WIDTH+1),
        .STAGES(SYNC_STAGES)
    ) wr_ptr_synchronizer (
        .clk(rd_clk),
        .ares(rd_ares),
        .data_in(wr_ptr_gray),
        .data_out(wr_ptr_gray_sync)
    );
    
    // Full and empty generation
    assign wr_full = (wr_ptr_gray[ADDR_WIDTH] != rd_ptr_gray_sync[ADDR_WIDTH]) &&
                     (wr_ptr_gray[ADDR_WIDTH-1] != rd_ptr_gray_sync[ADDR_WIDTH-1]) &&
                     (wr_ptr_gray[ADDR_WIDTH-2:0] == rd_ptr_gray_sync[ADDR_WIDTH-2:0]);
                     
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync);
    
    // Memory write operation
    always_ff @(posedge wr_clk) begin
        if (wr_en && !wr_full) begin
            fifo_mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end
    
    // Memory read operation
    assign rd_data = fifo_mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    
    // Error detection
    logic wr_overflow, rd_underflow;
    
    always_ff @(posedge wr_clk or posedge wr_ares) begin
        if (wr_ares) begin
            wr_overflow <= 1'b0;
        end else begin
            wr_overflow <= wr_overflow | (wr_en && wr_full);
        end
    end
    
    always_ff @(posedge rd_clk or posedge rd_ares) begin
        if (rd_ares) begin
            rd_underflow <= 1'b0;
        end else begin
            rd_underflow <= rd_underflow | (rd_en && rd_empty);
        end
    end
    
    assign overflow_error = wr_overflow;
    assign underflow_error = rd_underflow;
endmodule
```

### FIFO with Ready/Valid Protocol

Ready/Valid (or srdy/rrdy) protocol is commonly used for flow control in high-performance designs. This FIFO implementation supports this protocol with configurable options for performance and area optimization.

```systemverilog
// FIFO with ready/valid protocol
module gfx_srdy_rrdy_fifo #(
    parameter DEPTH = 8,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = $clog2(DEPTH),
    parameter REGISTER_OUTPUT = 1,  // Register output for timing
    parameter LOOKAHEAD = 1         // Enable lookahead for back-to-back transfers
)(
    input                       clk,
    input                       ares,
    
    // Input interface
    input                       in_srdy,
    output                      in_rrdy,
    input  [DATA_WIDTH-1:0]     in_data,
    
    // Output interface
    output                      out_srdy,
    input                       out_rrdy,
    output [DATA_WIDTH-1:0]     out_data,
    
    // Status
    output [ADDR_WIDTH:0]       occupancy,
    output                      full,
    output                      empty
);

    // Internal registers
    logic [ADDR_WIDTH:0]        wr_ptr;
    logic [ADDR_WIDTH:0]        rd_ptr;
    logic [DATA_WIDTH-1:0]      fifo_mem [0:DEPTH-1];
    logic                       output_valid;
    logic [DATA_WIDTH-1:0]      output_reg;
    
    // Control signals
    logic                       fifo_write;
    logic                       fifo_read;
    logic                       internal_empty;
    
    // Write and read pointers
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (fifo_write)
                wr_ptr <= wr_ptr + 1'b1;
            if (fifo_read)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end
    
    // Memory write operation
    always_ff @(posedge clk) begin
        if (fifo_write) begin
            fifo_mem[wr_ptr[ADDR_WIDTH-1:0]] <= in_data;
        end
    end
    
    // Occupancy calculation
    assign occupancy = wr_ptr - rd_ptr;
    assign full = occupancy == DEPTH;
    assign internal_empty = (wr_ptr == rd_ptr);
    
    // Input ready generation
    assign in_rrdy = ~full;
    assign fifo_write = in_srdy && in_rrdy;
    
    // Output path with optional registration
    generate
        if (REGISTER_OUTPUT) begin: REG_OUTPUT
            // Registered output path
            always_ff @(posedge clk or posedge ares) begin
                if (ares) begin
                    output_valid <= 1'b0;
                    output_reg <= '0;
                end else begin
                    if (fifo_read) begin
                        output_valid <= 1'b1;
                        output_reg <= fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
                    end else if (out_rrdy) begin
                        output_valid <= 1'b0;
                    end
                end
            end
            
            assign out_srdy = output_valid;
            assign out_data = output_reg;
            assign empty = internal_empty && ~output_valid;
            
            // Read logic with lookahead
            if (LOOKAHEAD) begin: LOOKAHEAD_ENABLED
                assign fifo_read = ~internal_empty && (~output_valid || out_rrdy);
            end else begin: STANDARD_READ
                assign fifo_read = ~internal_empty && ~output_valid;
            end
        end else begin: DIRECT_OUTPUT
            // Direct output path
            assign out_srdy = ~internal_empty;
            assign out_data = fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
            assign empty = internal_empty;
            assign fifo_read = out_srdy && out_rrdy;
        end
    endgenerate
endmodule
```

---

## 15. Memory Interface Design

Memory interfaces are critical components in digital systems, providing access to various memory types including SRAM, register files, and external memories. Proper memory interface design ensures optimal performance, reliability, and power efficiency.

### SRAM Interface Design

SRAM interfaces should be designed for maximum throughput while maintaining timing margins. Key considerations include address setup time, write enable timing, and read data latency. For high-performance designs, consider pipelining the interface to improve timing closure.

```systemverilog
// SRAM interface module with configurable parameters
module gfx_sram_interface #(
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 64,
    parameter WRITE_ENABLE_WIDTH = DATA_WIDTH/8,
    parameter READ_LATENCY = 1,
    parameter REGISTER_OUTPUTS = 1
)(
    input                               clk,
    input                               ares,
    
    // Client interface
    input                               req_valid,
    output                              req_ready,
    input                               req_write,
    input        [ADDR_WIDTH-1:0]       req_addr,
    input        [DATA_WIDTH-1:0]       req_wdata,
    input        [WRITE_ENABLE_WIDTH-1:0] req_wstrb,
    output                              resp_valid,
    output       [DATA_WIDTH-1:0]       resp_rdata,
    
    // SRAM interface
    output                              sram_cs,
    output                              sram_we,
    output       [ADDR_WIDTH-1:0]       sram_addr,
    output       [DATA_WIDTH-1:0]       sram_wdata,
    output       [WRITE_ENABLE_WIDTH-1:0] sram_wstrb,
    input        [DATA_WIDTH-1:0]       sram_rdata
);

    // Request handling
    logic                               req_accepted;
    logic                               read_pending;
    logic [READ_LATENCY-1:0]            read_valid_shift;
    
    // Accept requests when not busy
    assign req_ready = ~read_pending || (READ_LATENCY == 1 && resp_valid && ~req_write);
    assign req_accepted = req_valid && req_ready;
    
    // SRAM control signals
    assign sram_cs = req_accepted;
    assign sram_we = req_accepted && req_write;
    assign sram_addr = req_addr;
    assign sram_wdata = req_wdata;
    assign sram_wstrb = req_write ? req_wstrb : '0;
    
    // Read response tracking
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            read_valid_shift <= '0;
            read_pending <= 1'b0;
        end else begin
            // Shift register to track read latency
            read_valid_shift <= {read_valid_shift[READ_LATENCY-2:0], 
                                req_accepted && ~req_write};
            
            // Track pending reads
            if (req_accepted && ~req_write) begin
                read_pending <= 1'b1;
            end else if (resp_valid) begin
                read_pending <= 1'b0;
            end
        end
    end
    
    // Read data path
    generate
        if (REGISTER_OUTPUTS) begin: REG_OUTPUTS
            // Registered output for timing improvement
            logic [DATA_WIDTH-1:0] rdata_reg;
            
            always_ff @(posedge clk) begin
                if (read_valid_shift[READ_LATENCY-2]) begin
                    rdata_reg <= sram_rdata;
                end
            end
            
            assign resp_valid = read_valid_shift[READ_LATENCY-1];
            assign resp_rdata = rdata_reg;
        end else begin: DIRECT_OUTPUTS
            // Direct connection to SRAM outputs
            assign resp_valid = read_valid_shift[READ_LATENCY-1];
            assign resp_rdata = sram_rdata;
        end
    endgenerate
endmodule
```

### Register File Design

Register files require multi-port access with minimal latency. The design should optimize for area efficiency while maintaining high performance. For high-performance designs, consider banking the register file to support multiple simultaneous accesses.

```systemverilog
// Multi-port register file with configurable parameters
module gfx_register_file #(
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 32,
    parameter NUM_READ_PORTS = 2,
    parameter NUM_WRITE_PORTS = 1,
    parameter DEPTH = 2**ADDR_WIDTH,
    parameter RESET_REGS = 0,         // Set to 1 to reset all registers
    parameter FORWARDING_ENABLE = 1    // Enable write-to-read forwarding
)(
    input                                   clk,
    input                                   ares,
    
    // Read ports
    input  [NUM_READ_PORTS-1:0]                     rd_en,
    input  [NUM_READ_PORTS-1:0][ADDR_WIDTH-1:0]     rd_addr,
    output [NUM_READ_PORTS-1:0][DATA_WIDTH-1:0]     rd_data,
    
    // Write ports
    input  [NUM_WRITE_PORTS-1:0]                    wr_en,
    input  [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0]    wr_addr,
    input  [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0]    wr_data
);

    // Register file storage
    logic [DEPTH-1:0][DATA_WIDTH-1:0] registers;
    
    // Write logic with priority resolution
    always_ff @(posedge clk or posedge ares) begin
        if (ares && RESET_REGS) begin
            registers <= '0;
        end else begin
            // Process write ports in priority order (lower index has higher priority)
            for (int w = 0; w < NUM_WRITE_PORTS; w++) begin
                if (wr_en[w]) begin
                    registers[wr_addr[w]] <= wr_data[w];
                end
            end
        end
    end
    
    // Read logic with write forwarding
    generate
        for (genvar r = 0; r < NUM_READ_PORTS; r++) begin: READ_PORT
            if (FORWARDING_ENABLE) begin: WITH_FORWARDING
                // Forwarding logic to handle read-after-write hazards
                logic [DATA_WIDTH-1:0] forwarded_data;
                logic forwarding_active;
                
                always_comb begin
                    forwarded_data = registers[rd_addr[r]];
                    forwarding_active = 1'b0;
                    
                    // Check all write ports for forwarding (priority to lower indices)
                    for (int w = NUM_WRITE_PORTS-1; w >= 0; w--) begin
                        if (wr_en[w] && (wr_addr[w] == rd_addr[r])) begin
                            forwarded_data = wr_data[w];
                            forwarding_active = 1'b1;
                        end
                    end
                end
                
                assign rd_data[r] = rd_en[r] ? forwarded_data : '0;
            end else begin: NO_FORWARDING
                // Simple read without forwarding
                assign rd_data[r] = rd_en[r] ? registers[rd_addr[r]] : '0;
            end
        end
    endgenerate
endmodule
```

### Memory Controller Design

Memory controllers manage access to external memories like DDR SDRAM. They handle complex timing requirements, reordering for efficiency, and refresh operations. The design should optimize for bandwidth utilization while maintaining latency targets.

```systemverilog
// Memory controller with request reordering and timing management
module gfx_memory_controller #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 512,
    parameter ID_WIDTH = 8,
    parameter MAX_OUTSTANDING = 16,
    parameter REORDER_ENABLE = 1,
    parameter BANK_INTERLEAVE = 1
)(
    input                           clk,
    input                           ares,
    
    // Client request interface
    input                           req_valid,
    output                          req_ready,
    input                           req_write,
    input  [ADDR_WIDTH-1:0]         req_addr,
    input  [DATA_WIDTH-1:0]         req_wdata,
    input  [DATA_WIDTH/8-1:0]       req_wstrb,
    input  [ID_WIDTH-1:0]           req_id,
    
    // Client response interface
    output                          resp_valid,
    output [DATA_WIDTH-1:0]         resp_rdata,
    output [ID_WIDTH-1:0]           resp_id,
    output                          resp_error,
    
    // Memory PHY interface
    output                          mem_cmd_valid,
    input                           mem_cmd_ready,
    output [2:0]                    mem_cmd_opcode,
    output [ADDR_WIDTH-1:0]         mem_cmd_addr,
    output [7:0]                    mem_cmd_len,
    
    output                          mem_wr_valid,
    input                           mem_wr_ready,
    output [DATA_WIDTH-1:0]         mem_wr_data,
    output [DATA_WIDTH/8-1:0]       mem_wr_strb,
    output                          mem_wr_last,
    
    input                           mem_rd_valid,
    output                          mem_rd_ready,
    input  [DATA_WIDTH-1:0]         mem_rd_data,
    input                           mem_rd_last,
    input                           mem_rd_error
);

    // Request queue and tracking
    typedef struct packed {
        logic                       valid;
        logic                       write;
        logic [ADDR_WIDTH-1:0]      addr;
        logic [DATA_WIDTH-1:0]      wdata;
        logic [DATA_WIDTH/8-1:0]    wstrb;
        logic [ID_WIDTH-1:0]        id;
        logic [3:0]                 bank_id;
        logic                       scheduled;
    } mem_request_s;
    
    mem_request_s [MAX_OUTSTANDING-1:0] req_queue;
    logic [$clog2(MAX_OUTSTANDING)-1:0] enq_ptr, deq_ptr;
    logic [$clog2(MAX_OUTSTANDING):0]   queue_count;
    
    // Bank status tracking for reordering
    logic [15:0] bank_active;
    logic [15:0] bank_timer;
    
    // Queue management
    assign req_ready = (queue_count < MAX_OUTSTANDING);
    
    // Enqueue new requests
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            enq_ptr <= '0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                req_queue[i].valid <= 1'b0;
            end
        end else if (req_valid && req_ready) begin
            req_queue[enq_ptr].valid <= 1'b1;
            req_queue[enq_ptr].write <= req_write;
            req_queue[enq_ptr].addr <= req_addr;
            req_queue[enq_ptr].wdata <= req_wdata;
            req_queue[enq_ptr].wstrb <= req_wstrb;
            req_queue[enq_ptr].id <= req_id;
            req_queue[enq_ptr].bank_id <= req_addr[7:4]; // Example bank mapping
            req_queue[enq_ptr].scheduled <= 1'b0;
            
            enq_ptr <= enq_ptr + 1'b1;
        end
    end
    
    // Queue count tracking
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            queue_count <= '0;
        end else begin
            case ({req_valid && req_ready, mem_cmd_valid && mem_cmd_ready})
                2'b10: queue_count <= queue_count + 1'b1;
                2'b01: queue_count <= queue_count - 1'b1;
                default: queue_count <= queue_count;
            endcase
        end
    end
    
    // Request scheduling logic with bank interleaving
    logic [$clog2(MAX_OUTSTANDING)-1:0] schedule_ptr;
    logic schedule_valid;
    
    generate
        if (REORDER_ENABLE && BANK_INTERLEAVE) begin: REORDER_LOGIC
            // Reordering logic to optimize bank access patterns
            always_comb begin
                schedule_valid = 1'b0;
                schedule_ptr = deq_ptr;
                
                // First pass: look for requests to idle banks
                for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                    logic [$clog2(MAX_OUTSTANDING)-1:0] check_ptr;
                    check_ptr = (deq_ptr + i) % MAX_OUTSTANDING;
                    
                    if (req_queue[check_ptr].valid && !req_queue[check_ptr].scheduled &&
                        !bank_active[req_queue[check_ptr].bank_id]) begin
                        schedule_valid = 1'b1;
                        schedule_ptr = check_ptr;
                        break;
                    end
                end
                
                // Second pass: if no idle banks, take oldest request
                if (!schedule_valid) begin
                    for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                        logic [$clog2(MAX_OUTSTANDING)-1:0] check_ptr;
                        check_ptr = (deq_ptr + i) % MAX_OUTSTANDING;
                        
                        if (req_queue[check_ptr].valid && !req_queue[check_ptr].scheduled) begin
                            schedule_valid = 1'b1;
                            schedule_ptr = check_ptr;
                            break;
                        end
                    end
                end
            end
        end else begin: IN_ORDER_LOGIC
            // Simple in-order scheduling
            assign schedule_valid = req_queue[deq_ptr].valid && !req_queue[deq_ptr].scheduled;
            assign schedule_ptr = deq_ptr;
        end
    endgenerate
    
    // Memory command generation
    assign mem_cmd_valid = schedule_valid && !req_queue[schedule_ptr].scheduled;
    assign mem_cmd_opcode = req_queue[schedule_ptr].write ? 3'b001 : 3'b000; // Write/Read
    assign mem_cmd_addr = req_queue[schedule_ptr].addr;
    assign mem_cmd_len = 8'd0; // Single transfer
    
    // Mark request as scheduled
    always_ff @(posedge clk) begin
        if (mem_cmd_valid && mem_cmd_ready) begin
            req_queue[schedule_ptr].scheduled <= 1'b1;
            bank_active[req_queue[schedule_ptr].bank_id] <= 1'b1;
            bank_timer[req_queue[schedule_ptr].bank_id] <= 4'd10; // Example timing
        end
    end
    
    // Bank timing management
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            bank_active <= '0;
            bank_timer <= '0;
        end else begin
            for (int b = 0; b < 16; b++) begin
                if (bank_active[b]) begin
                    if (bank_timer[b] > 0) begin
                        bank_timer[b] <= bank_timer[b] - 1'b1;
                    end else begin
                        bank_active[b] <= 1'b0;
                    end
                end
            end
        end
    end
    
    // Write data channel
    assign mem_wr_valid = req_queue[deq_ptr].valid && req_queue[deq_ptr].scheduled && 
                         req_queue[deq_ptr].write;
    assign mem_wr_data = req_queue[deq_ptr].wdata;
    assign mem_wr_strb = req_queue[deq_ptr].wstrb;
    assign mem_wr_last = 1'b1; // Single transfer
    
    // Read data handling
    assign mem_rd_ready = 1'b1; // Always ready to receive read data
    
    // Response generation
    assign resp_valid = (mem_rd_valid && !req_queue[deq_ptr].write) || 
                       (mem_wr_valid && mem_wr_ready && req_queue[deq_ptr].write);
    assign resp_rdata = mem_rd_data;
    assign resp_id = req_queue[deq_ptr].id;
    assign resp_error = mem_rd_error;
    
    // Dequeue completed requests
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            deq_ptr <= '0;
        end else if (resp_valid) begin
            req_queue[deq_ptr].valid <= 1'b0;
            deq_ptr <= deq_ptr + 1'b1;
        end
    end
endmodule
```

---

## 16. Communication Protocols

Communication protocols enable reliable data exchange between modules, chips, and systems. Proper protocol implementation ensures interoperability, error detection, and efficient data transfer. This section covers common on-chip and chip-to-chip protocols used in digital systems.

### AXI Protocol Implementation

AXI (Advanced eXtensible Interface) is a widely used on-chip communication protocol that supports high-performance, flexible data transfers. The implementation should adhere to the ARM AMBA specification while optimizing for the specific design requirements.

```systemverilog
// AXI4 Master Interface
module gfx_axi_master #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64,
    parameter ID_WIDTH = 4,
    parameter USER_WIDTH = 1,
    parameter MAX_BURST_LEN = 16
)(
    input                           clk,
    input                           ares,
    
    // Client interface
    input                           req_valid,
    output                          req_ready,
    input                           req_write,
    input  [ADDR_WIDTH-1:0]         req_addr,
    input  [7:0]                    req_len,
    input  [2:0]                    req_size,
    input  [1:0]                    req_burst,
    input  [ID_WIDTH-1:0]           req_id,
    input  [DATA_WIDTH-1:0]         req_wdata,
    input  [DATA_WIDTH/8-1:0]       req_wstrb,
    
    output                          resp_valid,
    output [DATA_WIDTH-1:0]         resp_rdata,
    output [ID_WIDTH-1:0]           resp_id,
    output [1:0]                    resp_resp,
    
    // AXI interface
    // Write address channel
    output                          axi_awvalid,
    input                           axi_awready,
    output [ADDR_WIDTH-1:0]         axi_awaddr,
    output [7:0]                    axi_awlen,
    output [2:0]                    axi_awsize,
    output [1:0]                    axi_awburst,
    output [ID_WIDTH-1:0]           axi_awid,
    output [USER_WIDTH-1:0]         axi_awuser,
    
    // Write data channel
    output                          axi_wvalid,
    input                           axi_wready,
    output [DATA_WIDTH-1:0]         axi_wdata,
    output [DATA_WIDTH/8-1:0]       axi_wstrb,
    output                          axi_wlast,
    
    // Write response channel
    input                           axi_bvalid,
    output                          axi_bready,
    input  [ID_WIDTH-1:0]           axi_bid,
    input  [1:0]                    axi_bresp,
    
    // Read address channel
    output                          axi_arvalid,
    input                           axi_arready,
    output [ADDR_WIDTH-1:0]         axi_araddr,
    output [7:0]                    axi_arlen,
    output [2:0]                    axi_arsize,
    output [1:0]                    axi_arburst,
    output [ID_WIDTH-1:0]           axi_arid,
    output [USER_WIDTH-1:0]         axi_aruser,
    
    // Read data channel
    input                           axi_rvalid,
    output                          axi_rready,
    input  [DATA_WIDTH-1:0]         axi_rdata,
    input  [ID_WIDTH-1:0]           axi_rid,
    input  [1:0]                    axi_rresp,
    input                           axi_rlast
);

    // State machine definitions
    typedef enum logic [2:0] {
        IDLE,
        WRITE_ADDR,
        WRITE_DATA,
        WRITE_RESP,
        READ_ADDR,
        READ_DATA
    } axi_state_e;
    
    axi_state_e current_state, next_state;
    
    // Transaction tracking
    logic [7:0]                    burst_count;
    logic                          last_transfer;
    
    // State machine
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            current_state <= IDLE;
            burst_count <= '0;
        end else begin
            current_state <= next_state;
            
            if (current_state == IDLE && req_valid && req_ready) begin
                burst_count <= req_len;
            end else if ((current_state == WRITE_DATA && axi_wvalid && axi_wready) ||
                        (current_state == READ_DATA && axi_rvalid && axi_rready)) begin
                if (burst_count > 0) begin
                    burst_count <= burst_count - 1'b1;
                end
            end
        end
    end
    
    // Next state logic
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            IDLE: begin
                if (req_valid) begin
                    if (req_write) begin
                        next_state = WRITE_ADDR;
                    end else begin
                        next_state = READ_ADDR;
                    end
                end
            end
            
            WRITE_ADDR: begin
                if (axi_awvalid && axi_awready) begin
                    next_state = WRITE_DATA;
                end
            end
            
            WRITE_DATA: begin
                if (axi_wvalid && axi_wready && axi_wlast) begin
                    next_state = WRITE_RESP;
                end
            end
            
            WRITE_RESP: begin
                if (axi_bvalid && axi_bready) begin
                    next_state = IDLE;
                end
            end
            
            READ_ADDR: begin
                if (axi_arvalid && axi_arready) begin
                    next_state = READ_DATA;
                end
            end
            
            READ_DATA: begin
                if (axi_rvalid && axi_rready && axi_rlast) begin
                    next_state = IDLE;
                end
            end
        endcase
    end
    
    // Last transfer detection
    assign last_transfer = (burst_count == 0);
    
    // Client interface
    assign req_ready = (current_state == IDLE);
    
    // Write address channel
    assign axi_awvalid = (current_state == WRITE_ADDR);
    assign axi_awaddr = req_addr;
    assign axi_awlen = req_len;
    assign axi_awsize = req_size;
    assign axi_awburst = req_burst;
    assign axi_awid = req_id;
    assign axi_awuser = '0;
    
    // Write data channel
    assign axi_wvalid = (current_state == WRITE_DATA);
    assign axi_wdata = req_wdata;
    assign axi_wstrb = req_wstrb;
    assign axi_wlast = last_transfer;
    
    // Write response channel
    assign axi_bready = (current_state == WRITE_RESP);
    
    // Read address channel
    assign axi_arvalid = (current_state == READ_ADDR);
    assign axi_araddr = req_addr;
    assign axi_arlen = req_len;
    assign axi_arsize = req_size;
    assign axi_arburst = req_burst;
    assign axi_arid = req_id;
    assign axi_aruser = '0;
    
    // Read data channel
    assign axi_rready = (current_state == READ_DATA);
    
    // Response to client
    assign resp_valid = (axi_rvalid && axi_rready) || (axi_bvalid && axi_bready);
    assign resp_rdata = axi_rdata;
    assign resp_id = current_state == READ_DATA ? axi_rid : axi_bid;
    assign resp_resp = current_state == READ_DATA ? axi_rresp : axi_bresp;
endmodule
```

### Ready/Valid Protocol Implementation

Ready/Valid (or srdy/rrdy) protocol is a simple, flexible handshaking mechanism for flow control. It ensures data is only transferred when both sender and receiver are ready, preventing data loss and enabling backpressure.

```systemverilog
// Ready/Valid interface with parameterized data type
interface gfx_srdy_rrdy_if #(
    parameter DATA_WIDTH = 64
)(
    input clk
);
    logic                   srdy;
    logic                   rrdy;
    logic [DATA_WIDTH-1:0]  data;
    
    modport source (
        output srdy,
        output data,
        input  rrdy
    );
    
    modport sink (
        input  srdy,
        input  data,
        output rrdy
    );
    
    // Helper tasks for simulation and verification
    task automatic wait_for_transfer;
        @(posedge clk);
        while (!(srdy && rrdy)) @(posedge clk);
    endtask
    
    task automatic source_send(input [DATA_WIDTH-1:0] send_data);
        data <= send_data;
        srdy <= 1'b1;
        @(posedge clk);
        while (!rrdy) @(posedge clk);
        srdy <= 1'b0;
    endtask
    
    task automatic sink_receive(output [DATA_WIDTH-1:0] recv_data);
        rrdy <= 1'b1;
        @(posedge clk);
        while (!srdy) @(posedge clk);
        recv_data = data;
        rrdy <= 1'b0;
    endtask
endinterface

// Ready/Valid protocol adapter with configurable options
module gfx_srdy_rrdy_adapter #(
    parameter DATA_WIDTH = 64,
    parameter REGISTER_INPUT = 0,
    parameter REGISTER_OUTPUT = 1
)(
    input                           clk,
    input                           ares,
    
    // Input interface
    input                           in_srdy,
    output                          in_rrdy,
    input  [DATA_WIDTH-1:0]         in_data,
    
    // Output interface
    output                          out_srdy,
    input                           out_rrdy,
    output [DATA_WIDTH-1:0]         out_data
);

    generate
        if (REGISTER_INPUT && REGISTER_OUTPUT) begin: FULL_REGISTER
            // Full register slice with input and output registration
            logic                       mid_srdy;
            logic                       mid_rrdy;
            logic [DATA_WIDTH-1:0]      mid_data;
            
            // Input stage
            always_ff @(posedge clk or posedge ares) begin
                if (ares) begin
                    mid_srdy <= 1'b0;
                    mid_data <= '0;
                end else begin
                    if (!mid_srdy || mid_rrdy) begin
                        mid_srdy <= in_srdy;
                        if (in_srdy && in_rrdy) begin
                            mid_data <= in_data;
                        end
                    end
                end
            end
            
            assign in_rrdy = !mid_srdy || mid_rrdy;
            
            // Output stage
            always_ff @(posedge clk or posedge ares) begin
                if (ares) begin
                    out_srdy <= 1'b0;
                    out_data <= '0;
                end else begin
                    if (!out_srdy || out_rrdy) begin
                        out_srdy <= mid_srdy;
                        if (mid_srdy && mid_rrdy) begin
                            out_data <= mid_data;
                        end
                    end
                end
            end
            
            assign mid_rrdy = !out_srdy || out_rrdy;
            
        end else if (REGISTER_OUTPUT) begin: OUTPUT_REGISTER
            // Output-only registration
            always_ff @(posedge clk or posedge ares) begin
                if (ares) begin
                    out_srdy <= 1'b0;
                    out_data <= '0;
                end else begin
                    if (!out_srdy || out_rrdy) begin
                        out_srdy <= in_srdy;
                        if (in_srdy && in_rrdy) begin
                            out_data <= in_data;
                        end
                    end
                end
            end
            
            assign in_rrdy = !out_srdy || out_rrdy;
            
        end else if (REGISTER_INPUT) begin: INPUT_REGISTER
            // Input-only registration
            logic                       reg_srdy;
            logic [DATA_WIDTH-1:0]      reg_data;
            
            always_ff @(posedge clk or posedge ares) begin
                if (ares) begin
                    reg_srdy <= 1'b0;
                    reg_data <= '0;
                end else begin
                    if (!reg_srdy || out_rrdy) begin
                        reg_srdy <= in_srdy;
                        if (in_srdy && in_rrdy) begin
                            reg_data <= in_data;
                        end
                    end
                end
            end
            
            assign in_rrdy = !reg_srdy || out_rrdy;
            assign out_srdy = reg_srdy;
            assign out_data = reg_data;
            
        end else begin: DIRECT_CONNECT
            // Direct connection (combinational)
            assign out_srdy = in_srdy;
            assign in_rrdy = out_rrdy;
            assign out_data = in_data;
        end
    endgenerate
endmodule
```

### Credit-Based Flow Control

Credit-based flow control is useful for high-performance interfaces where traditional handshaking would introduce latency. It allows the sender to transmit data without waiting for per-transaction acknowledgment, using a credit system to prevent buffer overflow.

```systemverilog
// Credit-based flow control interface
module gfx_credit_flow_controller #(
    parameter DATA_WIDTH = 64,
    parameter CREDIT_WIDTH = 4,
    parameter BUFFER_DEPTH = 16
)(
    input                           clk,
    input                           ares,
    
    // Sender interface
    input                           send_valid,
    output                          send_ready,
    input  [DATA_WIDTH-1:0]         send_data,
    
    // Receiver interface
    output                          recv_valid,
    input                           recv_ready,
    output [DATA_WIDTH-1:0]         recv_data,
    
    // Credit interface
    input  [CREDIT_WIDTH-1:0]       init_credit,
    output                          credit_return,
    input                           credit_update,
    output [CREDIT_WIDTH-1:0]       credit_count
);

    // Credit tracking
    logic [CREDIT_WIDTH-1:0]        available_credits;
    
    // Data buffer
    logic [DATA_WIDTH-1:0]          buffer [0:BUFFER_DEPTH-1];
    logic [$clog2(BUFFER_DEPTH)-1:0] wr_ptr, rd_ptr;
    logic [$clog2(BUFFER_DEPTH):0]   buffer_count;
    
    // Credit management
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            available_credits <= init_credit;
        end else begin
            if (send_valid && send_ready && credit_update) begin
                // No change in credits (consume and return in same cycle)
                available_credits <= available_credits;
            end else if (send_valid && send_ready) begin
                // Consume a credit
                available_credits <= available_credits - 1'b1;
            end else if (credit_update) begin
                // Return a credit
                available_credits <= available_credits + 1'b1;
            end
        end
    end
    
    // Flow control
    assign send_ready = (available_credits > 0) && (buffer_count < BUFFER_DEPTH);
    
    // Buffer management
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            buffer_count <= '0;
        end else begin
            // Write to buffer
            if (send_valid && send_ready) begin
                buffer[wr_ptr] <= send_data;
                wr_ptr <= (wr_ptr + 1'b1) % BUFFER_DEPTH;
            end
            
            // Read from buffer
            if (recv_valid && recv_ready) begin
                rd_ptr <= (rd_ptr + 1'b1) % BUFFER_DEPTH;
            end
            
            // Update buffer count
            case ({send_valid && send_ready, recv_valid && recv_ready})
                2'b10: buffer_count <= buffer_count + 1'b1;
                2'b01: buffer_count <= buffer_count - 1'b1;
                default: buffer_count <= buffer_count;
            endcase
        end
    end
    
    // Output assignments
    assign recv_valid = (buffer_count > 0);
    assign recv_data = buffer[rd_ptr];
    assign credit_return = recv_valid && recv_ready;
    assign credit_count = available_credits;
endmodule
```

---

## 17. Synthesis Optimization and Constraints

Synthesis optimization and constraints are critical for achieving timing closure, area targets, and power goals. Proper constraint specification guides the synthesis tool to produce optimal results for the specific design requirements.

### Timing Constraints and Critical Paths

Timing constraints define the performance requirements for the design. They include clock definitions, input/output delays, and path-specific constraints. Critical paths should be identified and optimized early in the design process.

```systemverilog
// Timing-critical path optimization
// Use multicycle path constraints for paths with relaxed timing
(* multicycle_path = 2 *)
logic [31:0] relaxed_timing_reg;

// Use false path constraints for asynchronous crossings
(* async_reg = "true" *)
logic [1:0] sync_ff;

// Use max_delay constraints for critical paths
(* max_delay = "2.5ns" *)
logic [15:0] critical_data_path;

// Clock domain crossing synchronizer with timing constraints
module gfx_cdc_synchronizer #(
    parameter WIDTH = 1,
    parameter STAGES = 2
)(
    input                   dst_clk,
    input                   dst_ares,
    input  [WIDTH-1:0]      src_data,
    output [WIDTH-1:0]      dst_data
);
    // Synchronizer flip-flops with timing attributes
    (* async_reg = "true" *)
    logic [STAGES-1:0][WIDTH-1:0] sync_stages;
    
    always_ff @(posedge dst_clk or posedge dst_ares) begin
        if (dst_ares) begin
            sync_stages <= '0;
        end else begin
            sync_stages[0] <= src_data;
            for (int i = 1; i < STAGES; i++) begin
                sync_stages[i] <= sync_stages[i-1];
            end
        end
    end
    
    assign dst_data = sync_stages[STAGES-1];
endmodule
```

### Area Optimization Techniques

Area optimization reduces silicon cost and can improve power efficiency. Techniques include resource sharing, logic minimization, and architectural optimizations. The design should balance area efficiency with performance requirements.

```systemverilog
// Resource sharing for area optimization
module gfx_shared_alu #(
    parameter DATA_WIDTH = 32
)(
    input                           clk,
    input                           ares,
    
    // Control interface
    input                           operation_valid,
    output                          operation_ready,
    input  [2:0]                    operation_type,  // 0=ADD, 1=SUB, 2=MUL, 3=DIV, etc.
    
    // Data interface
    input  [DATA_WIDTH-1:0]         operand_a,
    input  [DATA_WIDTH-1:0]         operand_b,
    output [DATA_WIDTH-1:0]         result,
    output                          result_valid,
    
    // Status
    output                          busy
);
    // State machine for resource sharing
    typedef enum logic [2:0] {
        IDLE,
        EXECUTE_ADD_SUB,
        EXECUTE_MUL,
        EXECUTE_DIV,
        COMPLETE
    } alu_state_e;
    
    alu_state_e current_state, next_state;
    
    // Operation tracking
    logic [2:0]                     current_op;
    logic [DATA_WIDTH-1:0]          op_a_reg, op_b_reg;
    logic [DATA_WIDTH-1:0]          result_reg;
    logic [3:0]                     cycle_counter;
    
    // State machine
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            current_state <= IDLE;
            current_op <= '0;
            op_a_reg <= '0;
            op_b_reg <= '0;
            result_reg <= '0;
            cycle_counter <= '0;
        end else begin
            current_state <= next_state;
            
            // Register inputs when starting new operation
            if (current_state == IDLE && operation_valid) begin
                current_op <= operation_type;
                op_a_reg <= operand_a;
                op_b_reg <= operand_b;
                cycle_counter <= '0;
            end
            
            // Update cycle counter during execution
            if (current_state inside {EXECUTE_ADD_SUB, EXECUTE_MUL, EXECUTE_DIV}) begin
                cycle_counter <= cycle_counter + 1'b1;
            end
            
            // Compute result based on operation
            case (current_state)
                EXECUTE_ADD_SUB: begin
                    if (current_op == 3'd0) begin
                        result_reg <= op_a_reg + op_b_reg;
                    end else if (current_op == 3'd1) begin
                        result_reg <= op_a_reg - op_b_reg;
                    end
                end
                
                EXECUTE_MUL: begin
                    if (cycle_counter == 0) begin
                        // First cycle of multiplication
                        result_reg <= op_a_reg * op_b_reg;
                    end
                end
                
                EXECUTE_DIV: begin
                    if (cycle_counter == 0) begin
                        // First cycle of division
                        result_reg <= op_a_reg / op_b_reg;
                    end
                end
            endcase
        end
    end
    
    // Next state logic
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            IDLE: begin
                if (operation_valid) begin
                    case (operation_type)
                        3'd0, 3'd1: next_state = EXECUTE_ADD_SUB;
                        3'd2: next_state = EXECUTE_MUL;
                        3'd3: next_state = EXECUTE_DIV;
                        default: next_state = EXECUTE_ADD_SUB;
                    endcase
                end
            end
            
            EXECUTE_ADD_SUB: begin
                next_state = COMPLETE;
            end
            
            EXECUTE_MUL: begin
                if (cycle_counter >= 2) begin
                    next_state = COMPLETE;
                end
            end
            
            EXECUTE_DIV: begin
                if (cycle_counter >= 8) begin
                    next_state = COMPLETE;
                end
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
        endcase
    end
    
    // Output assignments
    assign operation_ready = (current_state == IDLE);
    assign result = result_reg;
    assign result_valid = (current_state == COMPLETE);
    assign busy = (current_state != IDLE);
endmodule
```

### Power Optimization Strategies

Power optimization reduces energy consumption and heat generation. Techniques include clock gating, power gating, and operand isolation. The design should implement power-saving features at all levels of the hierarchy.

```systemverilog
// Clock gating cell with integrated power optimization
module gfx_clock_gate_cell (
    input                           clk_in,
    input                           enable,
    input                           test_enable,
    output                          clk_out
);
    // Clock gating latch
    logic enable_latch;
    
    // Transparent latch, active low
    always_latch begin
        if (!clk_in) begin
            enable_latch <= enable || test_enable;
        end
    end
    
    // Clock gate
    assign clk_out = clk_in && enable_latch;
endmodule

// Power domain controller with isolation cells
module gfx_power_domain_controller #(
    parameter NUM_ISOLATION_SIGNALS = 8
)(
    input                           clk,
    input                           ares,
    
    // Power control signals
    input                           power_down_req,
    output                          power_down_ack,
    
    // Domain interface signals
    input  [NUM_ISOLATION_SIGNALS-1:0] domain_outputs,
    output [NUM_ISOLATION_SIGNALS-1:0] isolated_outputs,
    
    // Power control outputs
    output                          isolation_enable,
    output                          retention_enable,
    output                          power_switch_control
);
    // Power state machine
    typedef enum logic [2:0] {
        POWER_ON,
        ISOLATE,
        SAVE_STATE,
        POWER_OFF,
        RESTORE_STATE,
        DEISOLATE
    } power_state_e;
    
    power_state_e current_state, next_state;
    logic [3:0] state_counter;
    
    // State machine
    always_ff @(posedge clk or posedge ares) begin
        if (ares) begin
            current_state <= POWER_ON;
            state_counter <= '0;
        end else begin
            current_state <= next_state;
            
            if (current_state != next_state) begin
                state_counter <= '0;
            end else begin
                state_counter <= state_counter + 1'b1;
            end
        end
    end
    
    // Next state logic
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            POWER_ON: begin
                if (power_down_req) begin
                    next_state = ISOLATE;
                end
            end
            
            ISOLATE: begin
                if (state_counter >= 2) begin
                    next_state = SAVE_STATE;
                end
            end
            
            SAVE_STATE: begin
                if (state_counter >= 2) begin
                    next_state = POWER_OFF;
                end
            end
            
            POWER_OFF: begin
                if (!power_down_req) begin
                    next_state = RESTORE_STATE;
                end
            end
            
            RESTORE_STATE: begin
                if (state_counter >= 2) begin
                    next_state = DEISOLATE;
                end
            end
            
            DEISOLATE: begin
                if (state_counter >= 2) begin
                    next_state = POWER_ON;
                end
            end
        endcase
    end
    
    // Control signal generation
    assign isolation_enable = (current_state inside {ISOLATE, SAVE_STATE, POWER_OFF, RESTORE_STATE});
    assign retention_enable = (current_state inside {SAVE_STATE, POWER_OFF, RESTORE_STATE});
    assign power_switch_control = (current_state != POWER_OFF);
    assign power_down_ack = (current_state == POWER_OFF);
    
    // Isolation cells
    generate
        for (genvar i = 0; i < NUM_ISOLATION_SIGNALS; i++) begin: ISO_CELLS
            assign isolated_outputs[i] = isolation_enable ? 1'b0 : domain_outputs[i];
        end
    endgenerate
endmodule

// Operand isolation for combinational logic
module gfx_operand_isolation #(
    parameter WIDTH = 32
)(
    input                           clk,
    input                           enable,
    input  [WIDTH-1:0]              data_in,
    output [WIDTH-1:0]              data_out,
    
    // Function unit
    output [WIDTH-1:0]              operand_a,
    output [WIDTH-1:0]              operand_b,
    input  [WIDTH-1:0]              result
);
    // Operand isolation registers
    logic enable_reg;
    
    always_ff @(posedge clk) begin
        enable_reg <= enable;
    end
    
    // Isolate operands when not enabled
    assign operand_a = enable_reg ? data_in : '0;
    assign operand_b = enable_reg ? data_out : '0;
    
    // Output register
    always_ff @(posedge clk) begin
        if (enable_reg) begin
            data_out <= result;
        end
    end
endmodule
```

### Synthesis Directives and Pragmas

Synthesis directives and pragmas provide guidance to the synthesis tool for optimizing specific parts of the design. They can control resource allocation, timing constraints, and optimization strategies.

```systemverilog
// Synthesis directives for resource allocation
(* ram_style = "block" *)
logic [31:0] memory_array [0:1023];

// Force register duplication for fanout reduction
(* dont_merge = "true" *)
logic [15:0] high_fanout_reg;

// Preserve hierarchy for better debugging and incremental compilation
(* keep_hierarchy = "yes" *)
module gfx_preserved_module (
    // ports
);
    // implementation
endmodule

// Prevent logic optimization for timing-critical paths
(* dont_touch = "true" *)
logic [7:0] timing_critical_path;

// Specify maximum fanout for critical signals
(* max_fanout = 16 *)
logic reset_fanout_limited;

// Full-case and parallel-case directives for state machines
always_comb begin
    // synthesis full_case parallel_case
    case (state)
        // case statements
    endcase
end

// Resource sharing control
(* resource_sharing = "off" *)
module gfx_no_resource_sharing (
    // ports
);
    // implementation
endmodule

// Retiming control for pipeline optimization
(* retiming = "yes" *)
module gfx_retimed_pipeline (
    // ports
);
    // implementation with pipeline registers
endmodule
```

### Synthesis Constraints File Structure

Synthesis constraints should be organized in a clear, hierarchical structure to ensure proper application and maintainability. The constraints file should include clock definitions, timing exceptions, and design-specific constraints.

```tcl
# Example synthesis constraints file structure

# Global settings
set_operating_conditions -max slow
set_wire_load_model -name "5K_hvratio_1_4"

# Clock definitions
create_clock -period 1.0 -name clk_core [get_ports clk_core]
create_clock -period 2.0 -name clk_mem [get_ports clk_mem]
create_clock -period 4.0 -name clk_debug [get_ports clk_debug]

# Generated clocks
create_generated_clock -name clk_div2 -source [get_ports clk_core] -divide_by 2 [get_pins u_clk_div/clk_out]

# Clock groups (asynchronous domains)
set_clock_groups -asynchronous -group {clk_core clk_div2} -group {clk_mem} -group {clk_debug}

# Input/output delays
set_input_delay -clock clk_core -max 0.5 [all_inputs]
set_output_delay -clock clk_core -max 0.5 [all_outputs]

# Path-specific constraints
set_multicycle_path -setup 2 -from [get_pins u_slow_path/reg_a*/Q] -to [get_pins u_slow_path/reg_b*/D]
set_false_path -from [get_pins u_cdc/sync_ff_reg[0]/Q] -to [get_pins u_cdc/sync_ff_reg[1]/D]

# Area constraints
set_max_area 1000000

# Power constraints
set_max_dynamic_power 500mW
set_max_leakage_power 50mW

# Critical path optimization
set_critical_path_slacks -setup 0.1 [get_timing_paths -nworst 10]

# Fanout constraints
set_max_fanout 20 [current_design]
set_max_fanout 8 [get_pins */reset_reg/Q]

# Load constraints
set_load 0.1 [all_outputs]

# Transition constraints
set_max_transition 0.5 [current_design]
set_max_transition 0.2 [get_pins */critical_path*/Q]

# DFT constraints
set_dft_signal -view existing_dft -type ScanClock -timing {45 55} -port clk_core
set_dft_signal -view existing_dft -type Reset -active_state 1 -port ares
```