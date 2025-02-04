use clap::Parser;
use reth_optimism_cli::chainspec::OpChainSpecParser;
use reth_optimism_cli::Cli;
use world_chain_builder_node::args::ExtArgs;
use world_chain_builder_node::node::WorldChainBuilder;
use world_chain_builder_rpc::{
    sequencer::SequencerClient, EthTransactionsExtServer, WorldChainEthApiExt,
};

#[cfg(all(feature = "jemalloc", unix))]
#[global_allocator]
static ALLOC: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

fn main() {
    dotenvy::dotenv().ok();

    reth_cli_util::sigsegv_handler::install();
    eyre::install().unwrap();

    // Enable backtraces unless a RUST_BACKTRACE value has already been explicitly provided.
    if std::env::var_os("RUST_BACKTRACE").is_none() {
        std::env::set_var("RUST_BACKTRACE", "1");
    }

    // Set default log level
    if std::env::var_os("RUST_LOG").is_none() {
        std::env::set_var("RUST_LOG", "info,reth=info");
    }
    if let Err(err) =
        Cli::<OpChainSpecParser, ExtArgs>::parse().run(|builder, builder_args| async move {
            let handle = builder
                .node(WorldChainBuilder::new(builder_args.clone())?)
                .extend_rpc_modules(move |ctx| {
                    let provider = ctx.provider().clone();
                    let pool = ctx.pool().clone();
                    let sequencer_client = builder_args
                        .rollup_args
                        .sequencer_http
                        .map(SequencerClient::new);
                    let eth_api_ext = WorldChainEthApiExt::new(pool, provider, sequencer_client);
                    ctx.modules.replace_configured(eth_api_ext.into_rpc())?;
                    Ok(())
                })
                .launch()
                .await?;

            handle.node_exit_future.await
        })
    {
        eprintln!("Error: {err:?}");
        std::process::exit(1);
    }
}
