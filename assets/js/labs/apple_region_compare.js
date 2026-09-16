/* Apple 产品分区对比 — 两级机型选择与表格渲染 */
(function () {
  "use strict";

  const data = window.ARC_DATA;
  if (!data || !Array.isArray(data.categories) || !Array.isArray(data.regions)) {
    return;
  }

  const CUTOFF = "2020-01";
  const regions = data.regions;
  const statusMeta = {
    full: { icon: "fa-check", label: "完全支持" },
    hardware: { icon: "fa-microchip", label: "硬件不支持" },
    account: { icon: "fa-user-gear", label: "换区可用" },
    location: { icon: "fa-location-dot", label: "须在服务地区" },
    carrier: { icon: "fa-tower-cell", label: "运营商 / 监管" },
    model: { icon: "fa-code-branch", label: "视型号 / 批次" },
    locked: { icon: "fa-lock", label: "地区固件锁定" }
  };

  let activeCategory = "iphone";
  let activeProductId = "";

  function afterCutoff(released) {
    return (released || "") >= CUTOFF;
  }

  function getCategory(categoryId) {
    return data.categories.find(function (category) {
      return category.id === categoryId;
    });
  }

  function getProducts(categoryId) {
    const category = getCategory(categoryId);
    return category
      ? category.products.filter(function (product) {
          return afterCutoff(product.released);
        })
      : [];
  }

  function getComparisons(product) {
    if (product.comparisons && product.comparisons.length) {
      return product.comparisons;
    }
    return activeCategory === "iphone" ? data.matrix || [] : [];
  }

  function regionInfoSignature(info) {
    if (!info) return "__missing__";
    return JSON.stringify({
      model: info.model || "",
      diffs: info.diffs || []
    });
  }

  /*
   * 将内容完全相同的地区版本合并为一个表格列。地区不必相邻，
   * 例如澳版与欧版信息一致时会显示为“澳版 / 欧版”。
   */
  function groupIdenticalRegions(product) {
    const groups = [];

    regions.forEach(function (region) {
      const info = product.regions[region.key];
      if (!info) return;

      const signature = regionInfoSignature(info);
      const existing = groups.find(function (group) {
        return group.signature === signature;
      });

      if (existing) {
        existing.regions.push(region);
      } else {
        groups.push({
          signature: signature,
          regions: [region],
          info: info
        });
      }
    });

    return groups;
  }

  function renderModelSelector() {
    const selector = document.getElementById("modelSeg");
    if (!selector) return;

    const products = getProducts(activeCategory);
    if (!products.some(function (product) {
      return product.id === activeProductId;
    })) {
      activeProductId = products.length ? products[0].id : "";
    }

    selector.innerHTML = "";
    products.forEach(function (product) {
      const button = document.createElement("button");
      button.type = "button";
      button.className =
        "arc-model-btn" + (product.id === activeProductId ? " active" : "");
      button.dataset.product = product.id;
      button.textContent = product.name;
      button.addEventListener("click", function () {
        activeProductId = product.id;
        renderModelSelector();
        renderProductTable();
      });
      selector.appendChild(button);
    });
  }

  function statusCell(value, title) {
    const status = statusMeta[value] ? value : "model";
    const meta = statusMeta[status];
    const tooltip = title ? title + " · " + meta.label : meta.label;
    return (
      '<td class="cell cell-' +
      status +
      '" title="' +
      tooltip +
      '"><span class="arc-status arc-status-icon status-' +
      status +
      '" aria-label="' +
      meta.label +
      '"><i class="fa-solid ' +
      meta.icon +
      '"></i></span></td>'
    );
  }

  function renderProductTable() {
    const category = getCategory(activeCategory);
    const product = category
      ? getProducts(activeCategory).find(function (item) {
          return item.id === activeProductId;
        })
      : null;
    const table = document.getElementById("productMatrix");
    const summary = document.getElementById("productSummary");

    if (!table || !summary || !product) return;

    summary.innerHTML =
      '<strong>' +
      product.name +
      "</strong>" +
      '<span class="arc-product-date">发布：' +
      product.released +
      "</span>" +
      "<br>" +
      product.summary;

    const groups = groupIdenticalRegions(product);
    let head =
      '<tr><th class="sticky-col">差异维度</th>' +
      groups
        .map(function (group) {
          return (
            "<th>" +
            group.regions
              .map(function (region) {
                return (
                  '<span class="arc-group-region"><span class="rg-flag">' +
                  region.flag +
                  '</span><span class="rg-label">' +
                  region.label +
                  "</span></span>"
                );
              })
              .join('<span class="arc-region-separator">/</span>') +
            "</th>"
          );
        })
        .join("") +
      "</tr>";
    table.querySelector("thead").innerHTML = head;

    let body =
      '<tr><td class="sticky-col dim-cell"><span class="dim-name">型号 / 版本</span></td>' +
      groups
        .map(function (group) {
          return '<td class="arc-text-cell">' + (group.info.model || "—") + "</td>";
        })
        .join("") +
      "</tr>";

    const comparisons = getComparisons(product);
    if (comparisons.length) {
      comparisons.forEach(function (comparison) {
        body +=
          '<tr><td class="sticky-col dim-cell"><span class="dim-name">' +
          comparison.dim +
          "</span>" +
          (comparison.note
            ? '<span class="dim-note">' + comparison.note + "</span>"
            : "") +
          "</td>";

        groups.forEach(function (group) {
          const values = group.regions.map(function (region) {
            return comparison.cells[region.key] || "model";
          });
          const value = values.every(function (item) {
            return item === values[0];
          })
            ? values[0]
            : "model";
          body += statusCell(value, comparison.dim);
        });
        body += "</tr>";
      });
    }

    body +=
      '<tr><td class="sticky-col dim-cell"><span class="dim-name">地区版本差异</span></td>' +
      groups
        .map(function (group) {
          const diffs = group.info.diffs || [];
          return (
            '<td class="arc-text-cell"><ul class="arc-table-diffs">' +
            diffs
              .map(function (diff) {
                return "<li>" + diff + "</li>";
              })
              .join("") +
            "</ul></td>"
          );
        })
        .join("") +
      "</tr>";

    table.querySelector("tbody").innerHTML = body;
  }

  function renderFeatures() {
    const wrap = document.getElementById("featureList");
    if (!wrap) return;

    wrap.innerHTML = "";
    (data.features || []).forEach(function (feature) {
      const element = document.createElement("div");
      element.className = "arc-feature";
      element.innerHTML =
        '<div class="arc-feature-icon"><i class="' +
        feature.icon +
        '"></i></div>' +
        '<div class="arc-feature-body">' +
        '<h3 class="arc-feature-title">' +
        feature.title +
        "</h3>" +
        '<span class="arc-feature-by"><i class="fa-solid fa-sliders"></i> 取决于：' +
        feature.by +
        "</span>" +
        '<p class="arc-feature-desc">' +
        feature.desc +
        "</p>" +
        "</div>";
      wrap.appendChild(element);
    });
  }

  function bindCategorySelector() {
    const selector = document.getElementById("catSeg");
    if (!selector) return;

    selector.addEventListener("click", function (event) {
      const button = event.target.closest(".arc-seg-btn");
      if (!button || button.dataset.cat === activeCategory) return;

      selector.querySelectorAll(".arc-seg-btn").forEach(function (item) {
        item.classList.remove("active");
      });
      button.classList.add("active");
      activeCategory = button.dataset.cat;
      activeProductId = "";
      renderModelSelector();
      renderProductTable();
    });
  }

  function init() {
    renderModelSelector();
    renderProductTable();
    renderFeatures();
    bindCategorySelector();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();