# Fase 2 — Neovim como IDE principal. LSP para los lenguajes reales del
# trabajo (Python/Django, TS/JS, Nix). Deliberadamente sin nvim-cmp: Neovim
# 0.11+ trae completado LSP nativo (vim.lsp.completion), evita una
# dependencia más para algo que el editor ya resuelve solo.
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    extraPackages = with pkgs; [
      pyright
      typescript-language-server
      nixd
    ];

    plugins = with pkgs.vimPlugins; [
      nvim-treesitter.withAllGrammars
      telescope-nvim
      plenary-nvim
      lualine-nvim
      gitsigns-nvim
      nvim-lspconfig
      gruvbox-nvim
    ];

    initLua = ''
      vim.g.mapleader = " "
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.termguicolors = true

      vim.cmd.colorscheme("gruvbox")
      require("lualine").setup {}
      require("gitsigns").setup {}
      require("nvim-treesitter.configs").setup { highlight = { enable = true } }

      local builtin = require("telescope.builtin")
      vim.keymap.set("n", "<leader>ff", builtin.find_files, {})
      vim.keymap.set("n", "<leader>fg", builtin.live_grep, {})
      vim.keymap.set("n", "<leader>fb", builtin.buffers, {})

      local lspconfig = require("lspconfig")
      lspconfig.pyright.setup {}
      lspconfig.ts_ls.setup {}
      lspconfig.nixd.setup {}

      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          vim.lsp.completion.enable(true, args.data.client_id, args.buf, { autotrigger = true })
          local opts = { buffer = args.buf }
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
        end,
      })
    '';
  };
}
