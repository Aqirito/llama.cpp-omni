import Testing

@testable import ComniRuntime

@Test
func allocatesDistinctAvailableLoopbackPorts() throws {
  let allocator = LoopbackPortAllocator()
  let ports = try allocator.allocate(count: 4)

  #expect(ports.count == 4)
  #expect(Set(ports).count == 4)
  #expect(ports.allSatisfy(allocator.isAvailable))
}

@Test
func rejectsInvalidLoopbackPorts() {
  let allocator = LoopbackPortAllocator()

  #expect(!allocator.isAvailable(0))
  #expect(!allocator.isAvailable(65_536))
}
