//
//  MoveBridgeView.swift
//  ESPDeck Bridge
//
//  Moving the bridge to another Mac: the export sheet (a passphrase, then the save dialog)
//  and the import sheet (the file, its passphrase, what it holds, then replacing this Mac's
//  bridge). File ▸ Export Bridge… and Import Bridge…, the About page, and the empty window
//  open them through WindowState.bridgeTransfer. See DeckController+Transfer and
//  BridgeTransfer.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	/// An .espdeckbridge file, declared in Info.plist.
	nonisolated static let espDeckBridge = UTType( exportedAs: "com.tmproductions.espdeck.bridge-export" )
}

enum BridgeTransferSheet: String, Identifiable {
	case export
	case `import`

	var id: String { rawValue }
}

/// The encrypted export, for the save dialog.
private struct BridgeExportFile: FileDocument {
	static let readableContentTypes: [UTType] = [ .espDeckBridge ]

	var data: Data

	init( data: Data ) {
		self.data = data
	}

	init( configuration: ReadConfiguration ) throws {
		data = configuration.file.regularFileContents ?? Data()
	}

	func fileWrapper( configuration: WriteConfiguration ) throws -> FileWrapper {
		FileWrapper( regularFileWithContents: data )
	}
}

/// "1 device", "3 devices".
private func devicesText( _ count: Int ) -> String {
	count == 1 ? "1 device" : "\(count) devices"
}

// MARK: - Export

struct ExportBridgeSheet: View {
	let controller : DeckController

	@Environment( \.dismiss ) private var dismiss
	@State private var passphrase       = ""
	@State private var confirmation     = ""
	@State private var removeAfter      = false
	@State private var confirmingRemove = false
	@State private var working          = false
	@State private var document         : BridgeExportFile?
	@State private var exporting        = false
	@State private var problem          : String?

	private static let guidance = "Use at least \(BridgeTransfer.minimumPassphraseLength) characters; a few random words are easy to type and hard to guess. Anyone with the file and the passphrase can control your decks, and a forgotten passphrase can't be recovered."

	var body: some View {
		let weakness = BridgeTransfer.passphraseProblem( passphrase )
		let matches  = confirmation == passphrase
		let count    = controller.config.settings.devices.filter { !$0.isDemo }.count

		NavigationStack {
			Form {
				// Plain text over the form rather than a card of its own.
				Section {
					Text( "Saves this Mac's bridge in one file: its identity, the pairing keys of its \(devicesText( count )), the key layouts, icons, triggers and commands, and the developer password. On the other Mac, choose File ▸ Import Bridge… and enter the passphrase; the decks then connect to it without pairing again." )
						.listRowBackground( Color.clear )
						.listRowInsets( EdgeInsets( top: 0, leading: 4, bottom: 0, trailing: 4 ) )
				}

				Section {
					SecureField( "Passphrase", text: $passphrase, prompt: Text( "At least \(BridgeTransfer.minimumPassphraseLength) characters" ) )
					SecureField( "Passphrase Again", text: $confirmation )
				} footer: {
					if let weakness, !passphrase.isEmpty {
						Text( weakness ).foregroundStyle( .orange )
					} else if !confirmation.isEmpty && !matches {
						Text( "The passphrases don't match." ).foregroundStyle( .orange )
					} else {
						Text( Self.guidance )
					}
				}

				Section {
					Toggle( "Also remove this bridge from this Mac after exporting", isOn: $removeAfter )
						.toggleStyle( .switch )
				} footer: {
					Text( "Once the file is saved, this Mac forgets the pairing keys, devices, key layouts, icons and developer password, and starts over as a new bridge with no devices, so only the Mac you import the file on answers the decks. The decks stay paired with the bridge in the file." )
				}

				if let problem {
					Section {
						Label( problem, systemImage: "exclamationmark.triangle.fill" )
							.foregroundStyle( .orange )
					}
				}
			}
			.formStyle( .grouped )
			.navigationTitle( "Export Bridge" )
			.navigationBarTitleDisplayMode( .inline )   // centred between the buttons
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button {
						dismiss()
					} label: {
						Image( systemName: "xmark" )
					}
					.accessibilityLabel( "Cancel" )
					.help( "Cancel" )
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button( working ? "Encrypting…" : "Export…" ) {
						if removeAfter {
							confirmingRemove = true
						} else {
							export()
						}
					}
					.disabled( weakness != nil || !matches || working )
				}
			}
		}
		.frame( minWidth: 520, minHeight: 640 )   // everything shows without scrolling
		.fileExporter( isPresented: $exporting, document: document, contentType: .espDeckBridge, defaultFilename: "ESPDeck Bridge" ) { result in
			switch result {
				case .success:
					// Only once the file is safely written.
					if removeAfter {
						controller.removeBridge()
					}
					dismiss()
				case .failure( let error ):
					problem = "The file couldn't be saved: \(error.localizedDescription)"
			}
		}
		.confirmationDialog( "Remove the bridge from this Mac after saving?", isPresented: $confirmingRemove, titleVisibility: .visible ) {
			Button( "Export and Remove", role: .destructive ) { export() }
		} message: {
			Text( "Your decks will then work only with the Mac you import the file on, and only with this passphrase. If it's forgotten, each deck has to be unpaired on its setup page and paired again." )
		}
	}

	/// Encrypts off the main thread (the key derivation takes about a second), then asks
	/// where to save.
	private func export() {
		problem = nil
		working = true
		let passphrase = passphrase
		Task {
			defer { working = false }
			do {
				let archive = try controller.bridgeArchive()
				let data    = try await Task.detached( priority: .userInitiated ) {
					try BridgeTransfer.seal( archive, passphrase: passphrase )
				}.value
				document  = BridgeExportFile( data: data )
				exporting = true
			} catch {
				problem = "The bridge couldn't be exported: \(error.localizedDescription)"
			}
		}
	}
}

// MARK: - Import

struct ImportBridgeSheet: View {
	let controller : DeckController

	/// An export the user picked, before it's decrypted.
	private struct ChosenFile {
		var name : String
		var data : Data
	}

	@Environment( \.dismiss ) private var dismiss
	@State private var choosing          = false
	@State private var file              : ChosenFile?
	@State private var passphrase        = ""
	@State private var working           = false
	@State private var archive           : BridgeArchive?
	@State private var problem           : String?
	@State private var confirmingReplace = false
	/// What importing replaces here, read from the Keychain once.
	@State private var existing          = ( devices: 0, pairings: 0 )

	private var replacing: Bool { existing.devices > 0 || existing.pairings > 0 }

	private var replacement: String {
		existing.devices > 0 ? "This replaces this Mac's bridge: its \(devicesText( existing.devices )) and their pairings."
							 : "This replaces this Mac's bridge and its \(existing.pairings == 1 ? "pairing" : "\(existing.pairings) pairings")."
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					LabeledContent( "File" ) {
						HStack {
							Text( file?.name ?? "None chosen" )
								.foregroundStyle( .secondary )
								.lineLimit( 1 )
							Button( "Choose File…" ) { choosing = true }
								.disabled( working )
						}
					}
					if file != nil && archive == nil {
						SecureField( "Passphrase", text: $passphrase )
							.onSubmit { decrypt() }
					}
				} footer: {
					Text( "An export from ESPDeck Bridge on another Mac (File ▸ Export Bridge…), and the passphrase it was saved with." )
				}

				if let archive {
					Section {
						LabeledContent( "Exported", value: "\(archive.exported.formatted( date: .abbreviated, time: .shortened )) from \(archive.macName)" )
						let real  = archive.devices.filter { !$0.isDemo }
						let demos = archive.devices.count - real.count
						LabeledContent( "Devices", value: demos == 0 ? devicesText( real.count ) : "\(devicesText( real.count )), \(demos == 1 ? "1 demo deck" : "\(demos) demo decks")" )
						ForEach( real, id: \.id ) { device in
							LabeledContent( device.name, value: device.paired ? "paired" : "not paired" )
								.foregroundStyle( .secondary )
						}
					} header: {
						SectionHeader( "In This Export" )
					}

					Section {
						Label( "Only one Mac can be this bridge at a time. Quit ESPDeck Bridge on the other Mac or remove the bridge there, or the decks will switch between them.",
							   systemImage: "exclamationmark.triangle.fill" )
							.foregroundStyle( .orange )
						if replacing {
							Label( replacement, systemImage: "arrow.triangle.2.circlepath" )
						}
					}
				}

				if let problem {
					Section {
						Label( problem, systemImage: "exclamationmark.triangle.fill" )
							.foregroundStyle( .orange )
					}
				}
			}
			.formStyle( .grouped )
			.navigationTitle( "Import Bridge" )
			.navigationBarTitleDisplayMode( .inline )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button {
						dismiss()
					} label: {
						Image( systemName: "xmark" )
					}
					.accessibilityLabel( "Cancel" )
					.help( "Cancel" )
				}
				ToolbarItem( placement: .confirmationAction ) {
					if archive == nil {
						Button( working ? "Decrypting…" : "Decrypt" ) { decrypt() }
							.disabled( file == nil || passphrase.isEmpty || working )
					} else {
						Button( "Import" ) {
							if replacing {
								confirmingReplace = true
							} else {
								importArchive()
							}
						}
					}
				}
			}
		}
		.frame( minWidth: 480, minHeight: 460 )
		.onAppear { existing = controller.bridgeContents }
		.fileImporter( isPresented: $choosing, allowedContentTypes: [ .espDeckBridge ] ) { result in
			switch result {
				case .success( let url ):
					choose( url )
				case .failure( let error ):
					problem = error.localizedDescription
			}
		}
		.confirmationDialog( "Replace this Mac's bridge?", isPresented: $confirmingReplace, titleVisibility: .visible ) {
			Button( "Replace Bridge", role: .destructive ) { importArchive() }
		} message: {
			Text( "\(replacement) Decks paired with it stop working with this Mac until they're unpaired on their setup pages and paired again." )
		}
	}

	private func choose( _ url: URL ) {
		archive    = nil
		passphrase = ""
		do {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			if let size = try url.resourceValues( forKeys: [ .fileSizeKey ] ).fileSize, size > BridgeTransfer.maximumFileSize {
				throw BridgeTransfer.Problem.tooLarge
			}
			let data = try Data( contentsOf: url )
			_ = try BridgeTransfer.header( of: data )   // not an export, or a newer one: say so now
			file    = ChosenFile( name: url.lastPathComponent, data: data )
			problem = nil
		} catch {
			file    = nil
			problem = error.localizedDescription
		}
	}

	/// Off the main thread (the key derivation takes about a second). Nothing changes on this
	/// Mac until Import.
	private func decrypt() {
		guard let data = file?.data, !passphrase.isEmpty, !working else { return }
		working = true
		let passphrase = passphrase
		Task {
			defer { working = false }
			do {
				let opened = try await Task.detached( priority: .userInitiated ) {
					try BridgeTransfer.open( data, passphrase: passphrase )
				}.value
				_       = try controller.importableSettings( opened )
				archive = opened
				problem = nil
			} catch {
				problem = error.localizedDescription
			}
		}
	}

	private func importArchive() {
		guard let archive else { return }
		do {
			try controller.importBridge( archive )
			dismiss()
		} catch {
			problem = error.localizedDescription
		}
	}
}
